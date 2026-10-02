# Firmware Requirements

Status: draft. Companion to `README.md`, which describes the system.

## How to read this

- **shall** = required. **should** = desired, not blocking.
- Each requirement has a **Test** (measurable pass/fail) and a **Why**.
- Numbers are initial proposals unless they restate a hardware fact from the README. Revisit after bring-up.
- **PC interface:** joint-space SI units only (rad, rad/s, N·m). Transmission ratios stay in firmware config.
- **Time base:** one monotonic microsecond clock for all timestamps.
- **Out of scope:** mechanical, electrical, and PC-side software.
- **ID prefixes:** COM (I/O and communication), CTL (control), CAL (calibration), PRT (protection).

---

## 1. I/O and communication

### Motor drive and current sensing

**COM-1 PWM drive.** Each BTS7960 is driven at a fixed frequency of at least 20 kHz with at least 10-bit duty resolution.
- *Test:* scope each driver input. Frequency within ±1%; smallest duty step ≤ 0.1%.
- *Why:* keeps switching above audible range and current ripple low.

**COM-2 Default-off outputs.** All driver outputs are inactive from reset through init, and never produce torque during reset, brownout, or flashing.
- *Test:* logic analyzer on all driver inputs over 20 power cycles, 20 resets, 5 flashes. Zero active-drive pulses.
- *Why:* ESP32 pins float or pulse at boot, and a stray full-duty output on a 12 V / 29 A supply can throw the arm. Hardware pull-downs help, but firmware must not rely on them alone.

**COM-3 PWM-synchronized current sampling.** Sample each motor's IS signal inside that motor's high-side on-time, with margin from both PWM edges based on measured IS settling. If the on-time is too short for a valid sample, flag it invalid, hold the last valid value (or use a model estimate), and count invalid samples.
- *Test:* scope IS next to a GPIO toggled at each sample. Every sample is inside the window with margin. Compare against an inline meter at 5%–95% duty. Sweep duty up from 0% and confirm no spikes; report invalid count vs. duty.
- *Why:* IS only reads during high-side conduction. Sampling at other times gives wrong values, and at low duty the window can be shorter than mux settling plus conversion, which would feed garbage to the PI loop.

**COM-4 Per-cycle current update.** Each of the 7 motors gets a valid current sample at least once per control cycle through the shared mux and ADC.
- *Test:* per-channel sample counters over 1 hour, with the invalid fraction reported separately.
- *Why:* one mux and one ADC pin serve all channels, so select, settle, and convert must fit in the cycle budget.

**COM-5 Fault vs. overcurrent.** Distinguish a BTS7960 fault on IS from a real high-current reading. On a fault, disable that driver within one control cycle and flag it. Never use a fault reading as torque feedback.
- *Test:* bench fault injection (overcurrent into a resistive load until the driver trips) plus replay of captured traces. 100% correct classification.
- *Why:* faults share the IS pin with current sensing. A misclassified fault looks like a huge real current or hides a driver failure.

### Joint and motor sensing

**COM-6 Absolute encoders.** Read all 7 MT6701 encoders every cycle at a fixed phase, finishing within 25% of the control period. Hold the decoder address stable for the encoder's CS setup time before the first clock, and change the three address lines in one atomic write. Validate every frame with its CRC and magnetic-status fields and reject bad frames. A last-good value may be reused for at most 2 consecutive cycles, then the joint faults. Report error counters. CRC failure rate at the chosen clock is at most 1 in 10^6 frames.
- *Test:* logic analyzer on clock, data, and decoder outputs: no clock edges during address changes. Report acquisition time per cycle in telemetry. Run 1 hour under load with the PC link active and count CRC failures. Inject faults by unplugging a cable and misaligning a magnet.
- *Why:* a fixed read phase keeps velocity estimates clean, and a non-atomic address change glitches the 74HC138 and can select the wrong encoder. ~1 m cables next to seven H-bridges are noisy, and a corrupted angle in an impedance controller causes a torque spike. Choose the highest clock that meets the error rate with margin.

**COM-7 Motor-side velocity.** Read motor encoder counts every cycle with no lost counts at 6000 RPM. The velocity estimate must be filtered (not a raw finite difference), with at most 1°/s RMS noise at joint standstill and at least 50 Hz bandwidth (−3 dB). Fusing with the absolute encoder is allowed.
- *Test:* log at standstill and compute RMS. Sine-sweep a joint and compare against a filtered, differentiated reference.
- *Why:* the damping term depends on velocity, and a low-resolution encoder at 1 kHz gives coarse steps that would inject noise into the torque command.

### Gripper

**COM-8 Gripper.** Command the MG996R from the PC, with pulse width clamped to a configured safe range. Servo output must not affect control-loop jitter (CTL-1 holds with the gripper active).
- *Test:* check command accuracy with a protractor. Run the CTL-1 test with the gripper moving.
- *Why:* the gripper is outside the control loop but shares timing and peripherals.

### PC interface

**COM-9 Transport.** Use a wired serial link. Wi-Fi and Bluetooth stay off during operation unless CTL-1 is shown to hold with them on.
- *Test:* run CTL-1 with the link streaming at full rate.
- *Why:* the radio core is a major source of ESP32 timing jitter. (See Open Items.)

**COM-10 Framing and integrity.** Binary frames with length, sequence number, and CRC. Invalid frames are dropped and counted without crashing or stalling the controller.
- *Test:* feed corrupted, truncated, and oversized frames plus random bytes for 10 minutes. 100% rejected, no resets, counters correct.
- *Why:* a corrupted setpoint must never become a torque command.

**COM-11 Rates.** Stream state at 200 Hz or faster: joint angle, velocity, estimated joint torque, motor current, tendon state, mode, fault flags, loop-timing stats. Accept commands at any rate from 100 Hz to 1 kHz.
- *Test:* PC-side logging for 1 hour at maximum rates. Packet loss below 0.1%.
- *Why:* the PC needs state bandwidth for logging and higher-level control, and the loop must not depend on a particular command rate.

**COM-12 Command latency.** A valid command takes effect within 2 control periods of its last byte arriving.
- *Test:* logic analyzer: GPIO toggle on frame receipt vs. first changed control output.
- *Why:* PC-side loops need bounded, predictable latency.

**COM-13 Timestamps and sync.** Each state packet carries the microsecond timestamp of its sensor snapshot. A sync/ping message lets the PC estimate clock offset.
- *Test:* PC's offset estimate is within 200 µs of a logic-analyzer reference.
- *Why:* proper time alignment for logging, system identification, and PC-side estimation.

**COM-14 Command watchdog.** If no valid command arrives within a configurable timeout (default 50 ms) while any joint is enabled, enter the safe state (PRT-3) and raise a flag. Losing the PC link never stalls or disturbs the control loop.
- *Test:* unplug the cable mid-motion. Safe state within timeout + 2 control periods, and CTL-1 jitter is unaffected during and after.
- *Why:* the arm must fail safe if the PC crashes or the cable is pulled.

**COM-15 Command set.** At minimum: mode select (disabled, torque, impedance); joint setpoints (q_d, q̇_d, τ_ff); per-joint stiffness and damping; parameter get/set/persist; calibration commands (section 3); fault clear; gripper.
- *Test:* a PC-side test per command with a confirmed response.
- *Why:* defines the contract the PC software builds against.

---

## 2. Control

**CTL-1 Loop timing.** The loop runs at 1 kHz. Over at least 1 hour with all encoders read, all currents sampled, gripper active, and PC link at max rate: period within ±50 µs of 1000 µs, zero missed cycles (no period above 1.5 ms), worst-case execution time at most 60% of the period.
- *Test:* GPIO toggled each cycle, captured by a logic analyzer independent of firmware timers. Report execution time from a cycle counter in telemetry.
- *Why:* determinism, not compute, is the risk (flash-cache stalls, RTOS scheduling, radio core). Failing this after reasonable mitigation is the trigger to move to a Teensy 4.1.

**CTL-2 Sensor-to-actuation latency.** At most 500 µs from sensor snapshot to PWM update, with at most 20 µs jitter.
- *Test:* GPIO toggles at snapshot and PWM update, logic analyzer over 1 hour.
- *Why:* phase lag limits impedance gains, and latency jitter acts as torque noise.

**CTL-3 Impedance law.** Per joint: τ = K(q_d − q) + D(q̇_d − q̇) + τ_ff + τ_g(q), with q from the calibrated absolute encoder. K and D are settable at runtime and clamped to configured bounds.
- *Test:* hold q_d fixed and apply known loads (weight on a lever) in both directions. Deflection matches τ/K within ±15% at 3 poses and 3 values of K, averaging both directions to cancel friction.
- *Why:* this is the project's core behavior and needs a numeric acceptance criterion.

**CTL-4 Torque-to-current mapping.** i = τ / (N · η · k_t), with N, η, and k_t as per-joint config values changeable without reflashing.
- *Test:* change N via config and confirm joint torque scales. With a force gauge on a lever, torque is within ±15% of commanded at 25%, 50%, and 75% of the current limit.
- *Why:* the transmission is modular and ratios will change during tuning.

**CTL-5 Gravity compensation.** Compute τ_g(q) on the controller at the control rate from config parameters (link masses, centers of mass, kinematic offsets) loadable without reflashing. Worst-case compute time at most 100 µs. Provide a gravity-only mode (K = 0).
- *Test:* in gravity-only mode, release from 10 poses across the workspace. Drift under 2° in 10 s. Log compute time.
- *Why:* onboard computation means a PC dropout doesn't drop the arm, and parameters will change as the design evolves.

**CTL-6 Current loop.** Each motor has a PI current loop at 1 kHz or faster, with anti-windup and output clamped to achievable duty. For a 0 → 50% current-limit step: 10–90% rise time ≤ 5 ms, overshoot ≤ 20%, steady-state error ≤ 5% of the limit, both with the rotor locked and at 50% of free speed.
- *Test:* logged step responses under both conditions.
- *Why:* torque is proportional to current on a brushed motor, so this loop sets torque accuracy and repeatability.

**CTL-7 Enable sequence.** Boot into disabled. Enabling a joint requires valid calibration (or explicit override), no latched faults, and valid encoder data. On enable, initialize the setpoint to the current position and ramp torque from zero over at least 50 ms.
- *Test:* enable at 10 arbitrary poses with gravity compensation on. No joint moves more than 0.5° in the first 500 ms.
- *Why:* prevents a jump toward a stale setpoint.

**CTL-8 Setpoint and gain slew.** Rate-limit setpoint steps above a configured limit and slew gain changes over a configured time.
- *Test:* command a 0.5 rad step and a 2× change in K. Torque command stays within the slew limits.
- *Why:* a low-rate command stream and live tuning shouldn't produce step torques.

---

## 3. Calibration

All procedures start from the PC, run to completion with progress reporting, and return pass/fail with the computed metrics.

**CAL-1 Storage and integrity.** Store per-joint calibration and config (LUT, zero, range, current-sense trims, gains, transmission parameters, tendon baseline) in non-volatile memory with a schema version and CRC. Load at boot and allow export/import over the PC link. Missing or corrupt data puts the joint in an "uncalibrated" state.
- *Test:* corrupt an entry and confirm boot reports uncalibrated. Cut power at random times during 20 saves. Each time either the old or new data loads and passes CRC, never a mix.
- *Why:* corrupt calibration or gains can produce wrong torque, and power can drop mid-save.

**CAL-2 Zero, range, and wrap.** Record each joint's zero offset and travel limits from the absolute encoder, and place the encoder wrap point outside the working range.
- *Test:* repeat 10 times. Endpoints repeat within 0.25° and the angle has no discontinuity anywhere in range.
- *Why:* the MT6701 wraps at 360°, and limits, gravity, and impedance all need an unambiguous joint angle.

**CAL-3 Encoder LUT.** A per-joint table (at least 256 entries, linear interpolation) reduces angle error from the raw ±1° INL to ±0.1° or better. Applying it takes at most 10 µs per joint. Firmware provides a constant-velocity slow-sweep mode and full-rate capture (CAL-5) to support building the table. The table may be generated on the PC; firmware accepts an uploaded LUT and applies it.
- *Test:* compare against an independent reference accurate to ≤ 0.03°, at 20+ angles, both approach directions, across 2+ power cycles.
- *Why:* INL depends on magnet alignment and air gap, so the table is per-joint and must be redone after any reassembly.

**CAL-4 Current-sense calibration.** Trim per-channel zero offset and gain against a reference meter at 3+ current levels. Afterward, estimates are within ±5% or ±0.1 A (whichever is greater) over the full range, including ADC nonlinearity.
- *Test:* inline meter at 5 current levels per channel.
- *Why:* BTS7960 IS accuracy and ESP32 ADC linearity are both limited, and zero-current offset dominates torque error at the low torques impedance control mostly uses.

**CAL-5 Gain tuning support.** Store current-loop and default impedance gains per joint; changeable at runtime and persistable. Provide excitation modes (current step, torque step, position sine/chirp) and full-rate (1 kHz) capture of selected channels for at least 10 s with no dropped samples, streamed or buffered. An automated current-loop tuning routine is a *should*.
- *Test:* sequence numbers show zero gaps in a 10 s capture of 7 joints × 4 channels. Each excitation mode produces its commanded input.
- *Why:* gains are tuned off-board from logs. The ESP32-WROOM has no PSRAM, so buffering is limited and streaming may be required.

### Tendon monitoring

**CAL-6 Tendon state and baseline.**
- Tendon state for joint j is s_j = θ_motor,j / N_j − q_j, computed every cycle and reported in telemetry. It never feeds back into control.
- A baseline procedure sweeps each joint slowly in both directions at nominal tension and records s_j vs. angle and direction, plus a hysteresis band. It also reports the measured transmission ratio and flags a mismatch with the configured N_j above 1%.
- *Test:* unit-check s_j against logged positions. Repeat the baseline 5 times: agreement within 0.2° (joint) at all angles.
- *Why:* s_j is the observable for stretch, slack, and breakage. Real tendons have direction-dependent offset from friction and backlash, so detection must be relative to a measured baseline, not zero.

**CAL-7 Motor-encoder reference at boot.** Motor encoders are relative, so re-establish the motor-side zero against the absolute encoder at every boot (zero for CAL-6). Firmware should offer an optional startup coupling check: a small, current-limited torque in each direction, confirming a joint response.
- *Test:* power-cycle with tendons nominal, then with one deliberately slackened. The coupling check flags the slack case.
- *Why:* with a slack tendon the motor shaft can rest anywhere, so a boot-time zero would silently hide it.

**CAL-8 Slack and break detection.**
- (a) Deviation of s_j from baseline beyond T_slack (default 0.5° joint, configurable) for 100 ms raises a warning with the signed value.
- (b) Deviation beyond T_fault (default 3° joint, configurable), or motor motion beyond a configured amount with no joint motion, faults that joint and triggers the safe state within 20 ms of crossing.
- (c) Zero false flags over 1 hour of nominal motion, including reversals and load changes.
- *Test:* loosen a tensioner in known increments and confirm the reported deviation tracks it. With the arm supported, release a tendon: fault within 50 ms of divergence exceeding T_fault. Run the 1-hour false-positive test.
- *Why:* UHMWPE creeps, which slowly changes slack and backlash. A snapped cable leaves the joint uncontrolled under gravity while the motor saturates, so detection must be fast.

---

## 4. Protection and faults

**PRT-1 Current limits.** Each motor has configurable peak and continuous limits, enforced in every mode, with an I²t thermal model that derates, then faults. Limits sit below the per-motor fuse rating.
- *Test:* stall each motor at its limit. Current clamped within ±10%; I²t trip time matches the model within ±20%.
- *Why:* a brushed motor at 8.5 A stall overheats quickly. The fuse is the hardware backstop, not the primary protection.

**PRT-2 Fault classes.** Detect and report at least: encoder invalid, current-sense fault, overcurrent / I²t, bus overvoltage, command timeout, tendon slack warning, tendon fault, loop overrun, calibration invalid. Each has a severity (warn, disable joint, disable all). Faults latch until the condition has gone and the PC clears them.
- *Test:* inject each condition and confirm class, severity, latching, and clear behavior.
- *Why:* the operator needs to know what happened, and the system must not silently re-arm.

**PRT-3 Safe state.** Configurable among (a) controlled stop and hold, torque-limited, (b) active brake (low-side short), (c) outputs disabled. Reached within 2 control periods of fault detection. Defaults per fault class: see Open Items.
- *Test:* trigger each fault class with each option; measure time to safe state on a logic analyzer.
- *Why:* the right response depends on the fault. Dropping the arm under gravity and returning energy to the rail are different hazards.

**PRT-4 Regenerative energy.** If bus voltage is available to firmware: warn at 18 V, and fault into a safe state that doesn't return energy to the rail at 22 V. Also provide a configurable cap on braking torque / deceleration so the worst-case stop test peaks at or below 18 V with the hardware as built.
- *Test:* worst-case stop (max speed, hard stop command, with and without gravity assisting) with rail voltage on a scope. Peak ≤ 18 V.
- *Why:* the supply can't sink current, so deceleration pushes the rail toward the BTS7960's 27 V limit. If this fails, the fix is a hardware brake chopper, not more firmware limiting.

**PRT-5 Joint soft limits.** Beyond the CAL-2 limits, apply restoring torque and never command torque further into the limit.
- *Test:* command q_d beyond the limit. The joint stops within 1° of it with no limit-ward torque.
- *Why:* avoids hard-stop impacts and tendon slack at end of travel.

**PRT-6 Hang protection.** A hardware or task watchdog (timeout ≤ 50 ms) resets the controller on a firmware hang, returning outputs to default-off (COM-2). Enable brownout detection.
- *Test:* force an infinite loop while driving at 30% duty. Driver inputs go inactive within 50 ms.
- *Why:* PWM peripherals keep emitting the last duty when the CPU hangs, leaving a motor driven indefinitely.

---

## 5. Open items

1. **PC transport** (COM-9): USB-UART assumed. Baud rate and protocol library undecided.
2. **Current-loop rate** (CTL-6): at least 1 kHz required; whether to run faster than the outer loop is undecided.
3. **Default safe state per fault class** (PRT-3): not yet assigned.
4. **Bus-voltage sensing** (PRT-4): needs a hardware sense channel available to firmware.
5. **LUT reference method** (CAL-3): needs an independent angle reference accurate to ≤ 0.03°.
6. **Numeric thresholds:** all proposals, to be revised after bring-up.