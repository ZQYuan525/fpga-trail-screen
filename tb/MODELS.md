# Simulation model provenance

Production FIFO: `../ip/soft_fifo.v`, exact encrypted Anlogic Soft_FIFO 3.0 payload supplied with TD 6.2.1. ModelSim uses the vendor-supported encrypted model. No behavioral replacement is used for FIFO checks or frame integration.

Production SDRAM controller: `../ip/sdr_*.enc.v` and `../ip/sdram.v`. Pin-level simulation connects `sdram_model.v` to the compatible JEDEC model below. The SDRAM model is not the board's EM638325 silicon model; board timing remains a hardware acceptance item.

Vendored `vendor/mt48lc2m32b2.v` is byte-for-byte from:

- Repository: https://github.com/freecores/sdr_ctrl
- Commit: `4f3f0b4e000039e09bacbae41fe7db5a7309b5a8`
- Path: `verif/model/mt48lc2m32b2.v`
- SHA-256: `f4a9d4392aab3e6765d201d86dcd1350b9d1f5d6add016bbc5c79da1e1ac5060`
- Original Micron model header, copyright and disclaimer retained.
- The runner verifies the checksum before compilation; no network download is required.

`tb_frame_memory` defaults to a scoreboard-backed SDRAM application-interface model and **real Anlogic FIFO** to check full 640x480 frame handling. `tb_sdram_integration` selects the actual encrypted SDRAM controller and JEDEC pin model with width 640 / height 3; this covers physical row changes, refresh and a final 128-word burst. Do not describe the former as a full-frame physical SDRAM model run.

`sd_card_model.v` independently samples MOSI on SCK rising edges and drives MISO on falling edges, so the same model serves mode-0 and mode-3 hosts. Its fault modes are missing R1, R1 error, missing token, token at the timeout boundary, error token, missing CMD0 response, bad R7, unready OCR and permanently busy ACMD41. It asserts complete commands, initialization arguments, CMD55 before ACMD41, addresses and command CRC bytes.

`top_recovery` and `top_recovery_base` instantiate the production `top`, all repository IP wrappers/encrypted payloads, and the installed TD 6.2.1 EG4 simulation primitives (including the `glbl` root). The runner records hashes of these external model inputs as absolute paths. No PLL/HDMI/SDRAM/FIFO stubs or forced recovery signals are used. Only timer parameters and initialization SPI divider are shortened. The SD card model fault 11 returns bad CMD0 R1=0x04; fault 6 withholds CMD0 R1. Scenarios cover clean boot, transient errors, persistent failure with exactly three source resets, preserved first-fault diagnostics, reset isolation, and manual reset after exhaustion. Successful paths stop at first-image load start after the four-image scan; they do not prove complete frame display, production timer durations, or physical cold-boot reliability.

`top_load_recovery` injects fault 12: four catalog headers are valid, but the fifth CMD17 (first image load) returns a corrupt all-FF sector. It checks the production abort handshake and automatic next-image reload up to acceptance of a valid BMP header, while preserving the first-fault snapshot. This models a corrupt data response, not the electrical cause of the observed board failure.

`top_init_diagnostics` checks the real top's initialization command/R1 snapshot for bad CMD0 R1, CMD0 timeout, bad CMD8 R7, bad CMD58 OCR, and ACMD41 exhaustion. Live command detail clears on source retry, but the first-fault snapshot must survive. Installed EG4 models are isolated from the JEDEC integration model in `top_work`.
