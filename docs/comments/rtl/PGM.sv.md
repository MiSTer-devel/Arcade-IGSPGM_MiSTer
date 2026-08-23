# rtl/PGM.sv — commentary

### `cen_steady` — 68k clock enable (locked 2/5)

The 68k enable is an exact 2/5 of clk.  The real board runs the 68000 from
its own 20 MHz crystal, ~+5 ppm off the video crystal (measured: 337,921.7
CPU cycles per video frame vs 337,920.0 locked — LA capture la_wall2), so
hardware's CPU-to-IGS023 slot-schedule phase slips ~85 ns/frame and sweeps
every timing knife edge through all alignments; a locked enable sits at one
point of that beat.  A fractional-accumulator enable reproducing the drift
(ratio 0.4 × (1 + 5 ppm)) was implemented and then deliberately reverted:
it is more hardware-faithful in the ensemble sense, but the phase sweep
exposes sub-tick differences in the sim's bus-level access timing and made
the free-running ALL-window benchmark rows track hardware WORSE
(word_w/movem_w −1.3..−2.2%) than the locked enable does, while active-
window and gap-probe rows are beat-immune either way.  Consequence of the
locked enable: word/byte write ALL-window rows read ~+1.4% vs hardware
(the deterministic straggle rule never fires at the locked phase); the
hardware r/w ALL asymmetry is not reproduced.  Revisit only together with
pulse-level bus-timing fidelity in the CPU VRAM access path.

### `region`

The second MRA switch byte is a raw protection-region value, separate from
the active-low physical DIP bank.  ASIC3 uses its low three bits; IGS025 and
IGS027A consume the full byte according to their game-specific protocols.

### `BOARD_FLAG_SVG_OLD_IROM`

SVG 101HK and 101TW use an older internal ARM ROM layout than SVG 200.  The
board flag selects the corresponding region-patch offset without creating a
second game identifier.

### `ce_cpu` / `ce_cpu_180` chaser

`ce_cpu_count` chases `ce_steady_count` at up to one phi edge per clk
(25 MHz ceiling vs the 20 MHz target = 25% repayment headroom), pausing
while `sdr_cpu` fetches or `igs027a_share_ready` stalls are outstanding and
catching up afterwards, so average CPU speed stays 20 MHz for compute-bound
code.  Two limits: it cannot manufacture SDRAM bandwidth (memory-bound
stretches whose stall density exceeds the headroom lose time for real), and
the 10-bit `!=` comparison aliases if debt ever reaches 1024 CPU cycles,
silently forgiving exactly 1024 cycles per wrap event — one wrap/frame is
0.30%, almost exactly the espgalbl 3 s/16 min drift observed before the
ROM-starvation fixes.  A saturating compare would remove the alias
(still-open follow-up).
