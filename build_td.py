"""Build a provenance-recorded TD working copy; never generate outputs beside RTL."""
from __future__ import annotations
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

REPO = Path(__file__).resolve().parent
SOURCE = Path(__file__).resolve().parent
# TD install directory comes from TD_ROOT.
TD = Path(os.environ.get("TD_ROOT", "TD_6.2.1")) / "bin/td_commands_prompt.exe"

PROFILES = {"player": (0, 1), "base": (0, 0), "pattern": (1, 0), "tpg": (2, 0)}


def configure_run_strategies(project: ET.Element, pack_effort: str) -> None:
    """Persist the same settings GUI launch_runs reads (TD 6.2.1 format)."""
    runs = project.find("Runs")
    if runs is None:
        runs = ET.SubElement(project, "Runs")
    for name, kind, default, settings in (
        ("syn_1", "Synthesis", "Default_Synthesis_Strategy",
         {"GateProperty": {"map_mode": "area_prior", "pack_effort": pack_effort}}),
        ("phy_1", "PhysicalDesign", "Default_PhysicalDesign_Strategy",
         {"PlaceProperty": {"effort": "high", "opt_timing": "high"}, "RouteProperty": {"effort": "routability", "fix_hold": "on"}}),
    ):
        run = runs.find(f"Run[@Name='{name}']")
        if run is None:
            attrs = {"Name": name, "Type": kind, "ConstraintSet": "constraint_1", "Active": "true"}
            if kind == "PhysicalDesign":
                attrs["SynRun"] = "syn_1"
            run = ET.SubElement(runs, "Run", attrs)
        strategy = run.find("Strategy")
        if strategy is None:
            strategy = ET.SubElement(run, "Strategy", {"Name": default})
        for group, values in settings.items():
            element = strategy.find(group)
            if element is None:
                element = ET.SubElement(strategy, group)
            for key, value in values.items():
                setting = element.find(key)
                if setting is None:
                    setting = ET.SubElement(element, key)
                setting.text = value


def check_gui_step(out: Path, run: str, step: str) -> None:
    folder = out / "example_Runs" / run
    log = (folder / "run.log").read_text(encoding="utf-8", errors="replace")
    if (not (folder / f".{step}.end.f").is_file()
            or (folder / f".{step}.error.f").exists()
            or re.search(r"\b[A-Z]+-\d+\s+ERROR\b", log)):
        raise RuntimeError(f"GUI run failed: {folder}\n{log[-2000:]}")


def checked_td(out: Path, script_name: str, marker: str) -> None:
    log_path = out / (Path(script_name).stem + ".log")
    with log_path.open("wb") as log:
        result = subprocess.run([TD.as_posix(), (out / script_name).as_posix()], cwd=out,
                                stdout=log, stderr=subprocess.STDOUT, timeout=1800)
    output = log_path.read_text(encoding="utf-8", errors="replace")
    if (result.returncode or marker not in output
            or any(code in output for code in ("USR-8159", "USR-8012"))
            or re.search(r"\b[A-Z]+-\d+\s+ERROR\b", output)):
        errors = "\n".join(line for line in output.splitlines() if "ERROR" in line or "EXAMPLE_TD_FAILURE" in line)
        raise RuntimeError(f"TD failed: {log_path}\n{errors}\n{output[-2000:]}")


def read_slacks(path: Path) -> dict[str, float]:
    values = dict(re.findall(r"(SWNS|HWNS):\s*(-?\d+(?:\.\d+)?)ns", path.read_text(encoding="utf-8")))
    if set(values) != {"SWNS", "HWNS"}:
        raise RuntimeError(f"Missing timing metrics: {path}")
    return {key: float(value) for key, value in values.items()}


def repair_routed_hold(out: Path, gui_run: bool) -> dict[str, str]:
    """Run TD's explicit hold ECO, retaining the original route for audit."""
    db = Path("example_Runs/phy_1/example_pr.db" if gui_run else "routed.db")
    timing = Path("example_Runs/phy_1/example_phy.ts" if gui_run else "routed.ts")
    summary = Path("example_Runs/phy_1/example_pr.timing" if gui_run else "routed.timing")
    archive = out / "pre_hold_eco"
    archive.mkdir()
    for relative in (db, timing, summary):
        shutil.copy2(out / relative, archive / relative.name)
    script = f"""if {{[catch {{
import_device eagle_s20.db -package EG4S20BG256
open_project example.al
import_db {{{db.as_posix()}}}
fix_hold -clock_opt -eco
update_timing -mode final
report_timing_status -file {{{timing.as_posix()}}}
report_timing_summary -file {{{summary.as_posix()}}}
export_db {{{db.as_posix()}}}
puts "EXAMPLE_HOLD_ECO_PASS"
}} message]}} {{puts "EXAMPLE_HOLD_ECO_FAILURE: $message"; exit 1}}
exit 0
"""
    (out / "hold_eco.tcl").write_text(script, encoding="ascii")
    checked_td(out, "hold_eco.tcl", "EXAMPLE_HOLD_ECO_PASS")
    if gui_run:
        shutil.copy2(out / summary, out / "example_Runs/phy_1/final_timing.rpt")
    return {"before_db_sha256": hashlib.sha256((archive / db.name).read_bytes()).hexdigest(),
            "after_db_sha256": hashlib.sha256((out / db).read_bytes()).hexdigest(),
            "script_sha256": hashlib.sha256((out / "hold_eco.tcl").read_bytes()).hexdigest(),
            "log": str(out / "hold_eco.log")}


def git_head() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=REPO, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return "n/a"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--route", action="store_true")
    parser.add_argument("--bitstream", action="store_true", help="route, check timing, then generate a .bit in the build directory")
    parser.add_argument("--gui-run", action="store_true", help="use GUI launch_runs backend, check routed timing before bitgen")
    parser.add_argument("--hold-eco", action="store_true", help="repair residual hold paths after routing; preserve original route and recheck both slacks")
    parser.add_argument("--manual-persistence-start", action="store_true", help="diagnostic only: defer U33 boot access until physical KEY4; requires player persistence")
    parser.add_argument("--audio-diagnostics", action="store_true", help="diagnostic only: show live WAV/FIFO status; player profile only")
    parser.add_argument("--profile", choices=PROFILES, default="player")
    persistence = parser.add_mutually_exclusive_group()
    persistence.add_argument("--no-persistence", dest="no_persistence", action="store_true", default=True,
                             help="default: disable U33 reads/writes; keep media features")
    persistence.add_argument("--enable-persistence", dest="no_persistence", action="store_false",
                             help="include schema-2 U33 persistence (B/C/O/F/P/S/V/T); requires validated backup before board use")
    parser.add_argument("--pack-effort", choices=("medium", "high"), default="high",
                        help="TD gate packing effort; timing checks remain mandatory")
    parser.add_argument("--sd-div", type=int, choices=(3, 5, 25), default=5,
                        help="SPI half-period: 25=2MHz stable default, 3=16.67MHz experimental")
    args = parser.parse_args()
    if args.manual_persistence_start and (args.no_persistence or args.profile != "player"):
        parser.error("--manual-persistence-start requires --enable-persistence --profile player")
    if args.audio_diagnostics and args.profile != "player":
        parser.error("--audio-diagnostics requires --profile player")
    args.route = args.route or args.bitstream
    if args.hold_eco and not args.route:
        parser.error("--hold-eco requires --route or --bitstream")
    sandbox = REPO / "work" / "builds"
    sandbox.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix="player_next_td_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
                                + "_" + args.profile + ("_no_persistence_" if args.no_persistence else "_"), dir=sandbox))
    for name in ("rtl", "ip", "constraints"):
        shutil.copytree(SOURCE / name, out / name)
    # Only build configuration defaults change in the copy. Keep both hash sets.
    top_path = out / "rtl/top.v"
    top = top_path.read_text(encoding="utf-8")
    configuration = dict(zip(("DIAG_MODE", "ENABLE_EXTENSIONS"), PROFILES[args.profile]))
    configuration.update(ENABLE_FILESYSTEM=1, ENABLE_PERSISTENCE=int(not args.no_persistence),
                         SD_SPI_DIV=args.sd_div)
    if args.manual_persistence_start:
        configuration["PERSISTENCE_MANUAL_START"] = 1
    if args.audio_diagnostics:
        configuration["AUDIO_DIAGNOSTICS"] = 1
    for parameter, value in configuration.items():
        top, count = re.subn(r"(parameter integer " + parameter + r"\s*=\s*)\d+", rf"\g<1>{value}", top)
        if count != 1:
            raise RuntimeError(f"Missing unique top configuration: {parameter}")
    top_path.write_text(top, encoding="utf-8")
    if args.profile in ("pattern", "tpg"):
        # Storage is held in reset: FIFO Gray paths and constant status bundles
        # are optimized away. Keep all remaining I/O/PLL timing constraints.
        timing_path = out / "constraints/timing.sdc"
        timing = timing_path.read_text(encoding="utf-8")
        timing_path.write_text("\n".join(line for line in timing.splitlines()
                                          if not ((line.startswith("set_max_delay") and "get_regs" in line)
                                                  or (line.startswith("set_false_path -hold") and
                                                      any(instance in line for instance in ("u_status/", "u_image_status/", "u_panel_settings/"))))) + "\n",
                               encoding="utf-8")
    project = ET.fromstring((SOURCE / "example.al").read_text(encoding="utf-8").replace("UsedInP&R", "UsedInP&amp;R"))
    project.set("Path", out.as_posix())
    configure_run_strategies(project, args.pack_effort)
    (out / "example.al").write_text(ET.tostring(project, encoding="unicode").replace("UsedInP&amp;R", "UsedInP&R"), encoding="utf-8")
    provenance = {"source": str(SOURCE), "working_copy": str(out), "top": "top", "device": "EG4S20BG256",
                  "time": datetime.now().isoformat(),
                  "git_head": git_head(),
                  "sha256": {p.relative_to(SOURCE).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                             for base in (SOURCE / "rtl", SOURCE / "ip", SOURCE / "constraints")
                             for p in base.rglob("*") if p.is_file()}}
    provenance["sha256"]["example.al"] = hashlib.sha256((SOURCE / "example.al").read_bytes()).hexdigest()
    provenance["sha256"]["build_td.py"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    provenance["hold_eco"] = args.hold_eco
    provenance["profile"] = args.profile
    provenance["flow"] = "gui-runs" if args.gui_run else "direct-tcl"
    provenance["configuration"] = configuration
    provenance["strategy"] = {"map_mode": "area_prior", "pack_effort": args.pack_effort,
                              "place_effort": "high", "place_opt_timing": "high", "route_effort": "routability", "fix_hold": "on"}
    provenance["working_sha256"] = {p.relative_to(out).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
                                    for folder in (out / "rtl", out / "ip", out / "constraints")
                                    for p in folder.rglob("*") if p.is_file()}
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    script = """if {[catch {
import_device eagle_s20.db -package EG4S20BG256
open_project example.al
elaborate -top top
read_adc constraints/pin.adc
read_sdc constraints/timing.sdc
optimize_rtl
set_param gate map_mode area_prior
# Packing is configurable; each configuration must pass actual routing/timing.
set_param gate pack_effort PACK_EFFORT
optimize_gate -packarea gate.area
set area_file [open gate.area r]
set area_text [read $area_file]
close $area_file
foreach kind {lut reg bram dsp pll} {
    set pattern [format {#%s[ \t]+([0-9]+)[ \t]+out of[ \t]+([0-9]+)} $kind]
    if {![regexp $pattern $area_text match used available]} {error "Missing utilization: $kind"}
    if {$used > $available} {error "Device capacity exceeded: $kind $used/$available"}
}
legalize_phy_inst
update_timing
report_timing_status -file gate.ts
report_timing_summary -file gate.timing
export_db gate.db
ROUTE
puts "EXAMPLE_TD_PASS"
} message]} {
puts "EXAMPLE_TD_FAILURE: $message"
exit 1
}
exit 0
"""
    script = script.replace("PACK_EFFORT", args.pack_effort)
    script = script.replace("ROUTE", """set_param place effort high
set_param place opt_timing high
set_param route effort routability
set_param route fix_hold on
place
route
update_timing
report_timing_status -file routed.ts
report_timing_summary -file routed.timing
export_db routed.db""" if args.route else "")
    if args.gui_run:
        script = '''if {[catch {
import_device eagle_s20.db -package EG4S20BG256
open_project example.al
foreach {run step param expected} {
    syn_1 gate map_mode area_prior
    syn_1 gate pack_effort PACK_EFFORT
    phy_1 place effort high
    phy_1 place opt_timing high
    phy_1 route effort routability
    phy_1 route fix_hold on
} {
    set actual [get_param $step $param -run $run]
    if {$actual ne $expected} {error "GUI strategy mismatch: $run $step $param = $actual"}
}
launch_runs syn_1
wait_run syn_1
GUI_ROUTE
close_project
puts "EXAMPLE_TD_PASS"
} message]} {puts "EXAMPLE_TD_FAILURE: $message"; exit 1}
exit 0
'''.replace("PACK_EFFORT", args.pack_effort).replace("GUI_ROUTE", "launch_runs phy_1 -step opt_route\nwait_run phy_1" if args.route else "")
    (out / "build.tcl").write_text(script, encoding="ascii")
    for name in ("example.al", "build.tcl"):
        provenance["working_sha256"][name] = hashlib.sha256((out / name).read_bytes()).hexdigest()
    (out / "provenance.json").write_text(json.dumps(provenance, indent=2), encoding="utf-8")
    print(f"TD working copy: {out}", flush=True)
    checked_td(out, "build.tcl", "EXAMPLE_TD_PASS")
    if args.gui_run:
        check_gui_step(out, "syn_1", "opt_gate")
        if args.route:
            check_gui_step(out, "phy_1", "opt_route")
        timing = out / "example_Runs" / ("phy_1/example_phy.ts" if args.route else "syn_1/example_gate.ts")
    else:
        timing = out / ("routed.ts" if args.route else "gate.ts")
    hold_eco = repair_routed_hold(out, args.gui_run) if args.hold_eco else None
    slacks = read_slacks(timing)
    report = {"routed": args.route, "flow": provenance["flow"], "profile": args.profile, "configuration": configuration, "slack_ns": slacks,
              "timing_report": str(timing), "hold_eco": hold_eco}
    (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(report, flush=True)
    if args.route and any(float(v) < 0 for v in slacks.values()):
        raise RuntimeError(f"Routed timing violation: {out}")
    if args.bitstream:
        bit_script = """if {[catch {
import_device eagle_s20.db -package EG4S20BG256
open_project example.al
import_db routed.db
bitgen -bit example.bit
puts "EXAMPLE_BITGEN_PASS"
} message]} { puts "EXAMPLE_BITGEN_FAILURE: $message"; exit 1 }
exit 0
"""
        if args.gui_run:
            bit_script = '''if {[catch {
import_device eagle_s20.db -package EG4S20BG256
open_project example.al
launch_runs phy_1 -step bitgen
wait_run phy_1
close_project
puts "EXAMPLE_BITGEN_PASS"
} message]} {puts "EXAMPLE_BITGEN_FAILURE: $message"; exit 1}
exit 0
'''
        (out / "bitgen.tcl").write_text(bit_script, encoding="ascii")
        checked_td(out, "bitgen.tcl", "EXAMPLE_BITGEN_PASS")
        if args.gui_run:
            check_gui_step(out, "phy_1", "bitgen")
        bit = out / ("example_Runs/phy_1/example.bit" if args.gui_run else "example.bit")
        if not bit.is_file() or bit.stat().st_size == 0:
            raise RuntimeError(f"TD reported success without a bitstream: {out}")
        report["bitstream"] = {"path": str(bit), "sha256": hashlib.sha256(bit.read_bytes()).hexdigest(),
                               "bytes": bit.stat().st_size, "time": datetime.now().isoformat()}
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        print(f"Bitstream (not flashed): {bit}", flush=True)
    if args.gui_run:
        # TD rewrites XML formatting/compile order when closing a GUI project.
        # Preserve initial provenance and separately record the delivered file.
        report["project_after_run_sha256"] = hashlib.sha256((out / "example.al").read_bytes()).hexdigest()
        (out / "result.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

if __name__ == "__main__":
    main()
