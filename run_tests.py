"""Run self-checking RTL tests in isolated ModelSim libraries."""
from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parent
EXAMPLE = Path(__file__).resolve().parent
# Tool locations come from the environment (MODELSIM_BIN, TD_ROOT).
BIN = Path(os.environ.get("MODELSIM_BIN", "modelsim_ase/win32aloem"))
EG_MODELS = Path(os.environ.get("TD_ROOT", "TD_6.2.1")) / "sim_release/eg4"
# video_overlay instantiates the logo BRAM32K; its model needs the glbl top.
LOGO_MODELS = [EG_MODELS / "eg_phy_bram32k.v", EG_MODELS / "eg_phy_glbl.v"]
LOGO_HEX = EXAMPLE / "tb/logo_rom.hex"
# tb_scene_overlay checks glyphs, logo and grass against the make_scene_text.py /
# make_scene_art.py dumps.
SCENE_HEX = [EXAMPLE / f"tb/scene_{name}.hex" for name in ("font_lo", "font_hi", "title", "logo", "grass")]
DEFAULT_TESTS = [
    "filesystem_audio_stress", 
    "media_info", "audio_waveform", "thumbnail_preview", "preview_pipeline", "browse_controls", "direct_select", "advanced_overlay",
    "bad_first_media", "bad_media", "audio_gain", "player_panel", "extended_controls", "enhanced_overlay", "wipe_modes", "bad_images", "early_catalog", "early_images", "async_fifo", "spi_timing", "sd_protocol", "sd_host_reset", "sd_host_reset_delayed", "bmp_decoder",
    "sdram_integration", "memory_fault", "write_abort", "sd_player",
    "video", "axis_recovery", "control_audio", "frame_memory",
    "scaler", "spectrum", "bmp_flexible", "transition", "frame_fade", "player_fade", "controls", "overlay", "diagnostic", "ingest", "player_requests", "media_audio", "frame_status", "board_diagnostics", "sd_scan",
    "latency_breakdown", "latency_breakdown_2m", "media_recovery", "media_recovery_equivalence",
    "top_recovery", "top_recovery_base", "top_load_recovery", "top_init_diagnostics", "preload", "preload_cancel", "fat32_media", "wav_player", "startup_pulse", "board_inputs", "board_indicators", "logo_rom", "scene_overlay", "audio_source_mux", "filesystem_audio", "four_slot_memory", "filesystem_images",
]
# Opt-in only (long, measurement-oriented): not part of the default regression.
OPTIONAL_TESTS = [
    "load_latency_init", "load_latency_small", "load_latency_vga", "load_latency_big",
    "load_latency_vga_full",
]
MODEL_HASH = "f4a9d4392aab3e6765d201d86dcd1350b9d1f5d6add016bbc5c79da1e1ac5060"


def git_head() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return "n/a"


def command(args: list[str | Path], cwd: Path, log: Path) -> str:
    with log.open("wb") as stream:
        try:
            result = subprocess.run(
                [str(a) for a in args], cwd=cwd, stdout=stream,
                stderr=subprocess.STDOUT, timeout=3600,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"Simulation/build timeout; partial log: {log}") from exc
    output = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode or "** Error:" in output or "** Fatal:" in output:
        raise RuntimeError(f"Command failed: {log}\n{output[-5000:]}")
    return output


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*", default=DEFAULT_TESTS)
    parser.add_argument("--keep-going", action="store_true",
                        help="record a failing test and continue; exit nonzero at the end")
    args = parser.parse_args()
    unknown = set(args.tests) - set(DEFAULT_TESTS) - set(OPTIONAL_TESTS)
    if unknown:
        parser.error(f"Unknown tests: {sorted(unknown)}")
    sandbox = REPO / "work" / "tests"
    sandbox.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="player_next_tests_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f") + "_", dir=sandbox))
    print(f"ModelSim working copy: {out}", flush=True)
    library = out / "work"
    sources = [*sorted((EXAMPLE / "rtl").glob("*.v")), *sorted((EXAMPLE / "ip/fft").glob("*.v"))]
    benches = [EXAMPLE / "tb" / f"tb_{name}.v" for name in args.tests]
    top_recovery = bool({"top_persistence_audio", "top_persistence_boot", "top_recovery", "top_recovery_base", "top_load_recovery", "top_init_diagnostics"} & set(args.tests))
    if top_recovery or {"sd_protocol", "sd_host_reset", "sd_host_reset_delayed", "sd_scan", "latency_breakdown", "latency_breakdown_2m"} & set(args.tests):
        benches.append(EXAMPLE / "tb/sd_card_model.v")
    if any(name.startswith("load_latency_") for name in args.tests):
        benches += [EXAMPLE / "tb/load_latency_chain.v", EXAMPLE / "tb/sd_image_card_model.v"]
    if "sd_host_reset_delayed" in args.tests and "sd_host_reset" not in args.tests:
        benches.append(EXAMPLE / "tb/tb_sd_host_reset.v")
    if "top_recovery_base" in args.tests and "top_recovery" not in args.tests:
        benches.append(EXAMPLE / "tb/tb_top_recovery.v")
    if {"sdram_integration", "four_slot_memory"} & set(args.tests) and "frame_memory" not in args.tests:
        benches.append(EXAMPLE / "tb/tb_frame_memory.v")
    if "top_persistence_audio" in args.tests and "top_persistence_boot" not in args.tests:
        benches.append(EXAMPLE / "tb/tb_top_persistence_boot.v")
    if "media_recovery_equivalence" in args.tests:
        benches.append(EXAMPLE / "tb/media_recovery_reference.v")
    memory_sources: list[Path] = []
    if {"frame_memory", "sdram_integration", "four_slot_memory"} & set(args.tests):
        model = EXAMPLE / "tb/vendor/mt48lc2m32b2.v"
        if hashlib.sha256(model.read_bytes()).hexdigest() != MODEL_HASH:
            raise RuntimeError("Unexpected SDRAM model checksum")
        memory_sources = [
            *sorted((EXAMPLE / "ip").glob("sdr*.enc.v")),
            EXAMPLE / "ip/sdram.v", model, EXAMPLE / "tb/sdram_model.v",
        ]
    top_sources: list[Path] = []
    if top_recovery:
        top_sources = sorted(EG_MODELS.glob("*.v"))
        if not top_sources:
            raise RuntimeError(f"Missing Anlogic EG4 simulation models: {EG_MODELS}")
        top_sources += [p for p in sorted((EXAMPLE / "ip").glob("*.v"))
                        if p.name not in {"soft_fifo.v", "global_def.v"}]
    audio_tests = {"top_persistence_audio"}
    audio_sink = EXAMPLE / "tb/hdmi_audio_input_sink.v"
    inputs = [
        EXAMPLE / "ip/soft_fifo.v", *sources, *benches, *memory_sources, *top_sources, *LOGO_MODELS, LOGO_HEX, *SCENE_HEX,
        EXAMPLE / "ip/global_def.v", Path(__file__).resolve(),
    ]
    if audio_tests & set(args.tests):
        inputs.append(audio_sink)
    # Capture inputs BEFORE compilation/testing; edits during a long simulation
    # must never be reported as though they were the code that was compiled.
    provenance = {
        "time": datetime.now().isoformat(),
        "git_head": git_head(),
        "sha256": {str(p.relative_to(REPO) if p.is_relative_to(REPO) else p):
                   hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
    }
    (out / "inputs.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    command([BIN / "vlib.exe", library], out, out / "vlib.log")
    command([BIN / "vlog.exe", "-work", library, EXAMPLE / "ip/soft_fifo.v", *LOGO_MODELS], out, out / "vendor_compile.log")
    for hex_file in [LOGO_HEX, *SCENE_HEX]:
        (out / hex_file.name).write_bytes(hex_file.read_bytes())
    command([BIN / "vlog.exe", "-sv", "-work", library, *sources, *benches], out, out / "rtl_compile.log")
    if memory_sources:
        command([
            BIN / "vlog.exe", "-permissive", "-suppress", "2121", "-work", library,
            "+incdir+" + (EXAMPLE / "ip").as_posix(), *memory_sources,
        ], out, out / "sdram_compile.log")
    if top_sources:
        # The JEDEC integration bench supplies its own EG_PHY_SDRAM_2M_32.
        # Keep the installed primitive of that name in a separate library.
        top_library = out / "top_work"
        command([BIN / "vlib.exe", top_library], out, out / "top_vlib.log")
        command([BIN / "vlog.exe", "-work", top_library, EXAMPLE / "ip/soft_fifo.v"],
                out, out / "top_fifo_compile.log")
        command([BIN / "vlog.exe", "-sv", "-work", top_library, *sources, *benches],
                out, out / "top_rtl_compile.log")
        command([
            BIN / "vlog.exe", "-permissive", "-suppress", "2121", "-work", top_library,
            "+incdir+" + (EXAMPLE / "ip").as_posix(), *top_sources,
        ], out, out / "top_vendor_compile.log")
    if audio_tests & set(args.tests):
        # Separate library: never replace the vendor HDMI core in boot tests.
        audio_library = out / "audio_work"
        audio_sources = [p for p in top_sources if p.name != "hdmi_1_4b_transmitter_core_wrapper.enc.v"]
        command([BIN / "vlib.exe", audio_library], out, out / "audio_vlib.log")
        command([BIN / "vlog.exe", "-work", audio_library, EXAMPLE / "ip/soft_fifo.v"],
                out, out / "audio_fifo_compile.log")
        command([BIN / "vlog.exe", "-sv", "-work", audio_library, *sources, *benches, audio_sink],
                out, out / "audio_rtl_compile.log")
        command([BIN / "vlog.exe", "-permissive", "-suppress", "2121", "-work", audio_library,
                 "+incdir+" + (EXAMPLE / "ip").as_posix(), *audio_sources],
                out, out / "audio_vendor_compile.log")
    macro = out / "run.do"
    macro.write_text("onerror {quit -code 1}\nonbreak {quit -code 1}\nrun -all\nquit -code 0\n", encoding="ascii")
    results = []
    for name in args.tests:
        top_test = name in {"top_persistence_audio", "top_persistence_boot", "top_recovery", "top_recovery_base", "top_load_recovery", "top_init_diagnostics"}
        test_library = audio_library if name in audio_tests else top_library if top_test else library
        try:
            text = command([
                BIN / "vsim.exe", "-c", "-lib", test_library, f"tb_{name}", "glbl",
                "-do", "do {" + macro.as_posix() + "}",
            ], out, out / f"{name}.log")
            if "PASS" not in text or "FAIL" in text or "FATAL" in text:
                raise RuntimeError(f"Missing test pass: {out / (name + '.log')}\n{text[-5000:]}")
        except RuntimeError:
            if not args.keep_going:
                raise
            results.append({"test": name, "status": "FAIL"})
            print(f"FAIL {name}", flush=True)
        else:
            results.append({"test": name, "status": "PASS"})
            print(f"PASS {name}", flush=True)
        report = {**provenance, "results": results}
        (out / "results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    if any(r["status"] != "PASS" for r in results):
        raise SystemExit(f"FAILED: {[r['test'] for r in results if r['status'] != 'PASS']}")


if __name__ == "__main__":
    main()
