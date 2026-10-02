# 7-DOF Tendon-Driven Robot Arm

## 1. Purpose and priorities

A 7-DOF robot arm built from scratch, with a reach of roughly 60-70 cm. The design optimizes for **precision and low cost** over raw payload. Where those goals conflict, precision and cost win.

Joint torque is intentionally not a fixed target. The transmission is modular (see §2), so per-joint torque is tuned empirically by changing ratios rather than redesigning the actuation.

## 2. Architecture

**All motors sit in the base, next to the control board.** Power reaches each joint through tendons rather than joint-mounted actuators. This removes the reflected inertia of distal motors from the proximal joints, which is the core reason for the design. A lighter distal arm is easier to control precisely and is back-drivable enough for impedance control.

**Each joint is driven by two tendons wound in opposite senses on a single capstan.** One motor gives bidirectional actuation. Consequences:

- This is *not* a true antagonistic pair. Both tendons are kinematically coupled through one shaft, so there is no co-contraction and no active stiffness control. Joint stiffness comes from the controller (impedance control), not from the mechanism.
- Each joint is one motor, one capstan, and one absolute encoder. The tendon routing is invisible to the controller except through the tendon-state signal described in §4.

**Tendons are braided UHMWPE (Dyneema/Spectra)** for near-zero stretch. The line still creeps over time, so tension is set by a mechanical adjuster (turnbuckle or spring idler), independent of the capstan. Tension is a maintenance item, not something the controller adjusts. The controller's role is to *detect* when it has drifted (§4).

**Idler pulleys at intermediate joints** are mounted on their own bearings, concentric with that joint's rotation axis. Off-center pulleys would change tendon path length as the joint moves and cross-couple joints. Concentric mounting keeps each joint's motor-to-joint mapping independent, so each joint can be controlled as its own SISO loop. Idlers use a steel shaft through a 608-class bearing, with a printed pulley body around the bearing OD.

**Torque per joint is set by the capstan-to-joint-pulley diameter ratio**, not by stocking different motors. Total reduction is split between any internal gearbox and the capstan ratio. The ratio differs per joint and is expected to change during tuning, so the motor-to-joint scaling is a per-joint configuration parameter, not a global constant.

## 3. Actuation

- **Joint motors:** REV HD Hex brushed DC (0.105 Nm stall, 8.5 A stall, 6000 RPM free speed).
- **Torque control:** Brushed DC torque is proportional to current with no commutation, so torque control is a single PI current loop per motor.
- **Drivers:** One BTS7960 H-bridge per motor, driven through 74AHCT125 level shifters (ESP32 3.3 V logic to the driver's 5 V logic).
- **Gripper:** MG996R servo on its own 6 V rail, separate from the joint motor supply.

## 4. Sensing

There are three independent signals per joint.

**Absolute joint angle (MT6701).** A 14-bit magnetic absolute encoder at each joint is the ground-truth position. It is read over SSI/SPI with an individual chip select per encoder, across ~1 m cable runs from the base. Raw INL is about ±1°. A per-joint lookup table calibrates this to roughly ±0.1°. Mechanical requirements: a diametrically magnetized magnet on the joint shaft end, a 0.25-1 mm air gap, and under 0.3 mm off-axis misalignment. The long cable runs make SPI timing and signal integrity something to watch.

**Motor-side relative encoder.** This provides velocity for the control loop. Its position is also useful as slow telemetry. The difference between motor position scaled through the capstan ratio and the joint's absolute angle is the **tendon state**, which detects stretch, slack, or a snapped cable. This runs as a background health check, not in the control loop.

**Motor current (BTS7960 IS pin, sense ratio 8500).** This is the feedback for the torque loop. Two behaviors shape the design:

1. The IS pin only reports current *during high-side conduction* (PWM on-time). Samples must be synchronized to the PWM on-time. Sampling at arbitrary times gives wrong readings and corrupts the torque loop.
2. Faults appear on the same pin as a constant current source. A fault must be distinguishable from a genuinely high current reading, or one will be misclassified as the other.

## 5. Electronics

- **Controller:** ESP32 WROOM as the central controller.
- **Topology:** All motors are in the base, so there is no CAN bus. Drivers connect directly to the controller.
- **Signal multiplexing:** A CD74HC4067 analog mux collects the IS signals into one ADC pin. A 74HC138 decoder generates encoder chip selects from three pins.
- **Binding constraint:** **Pin count, not compute, is the limiting resource.** The mux and decoder exist for that reason, and the pin budget is already allocated. The multiplexing also means the current-sense and encoder paths have sequencing and settling-time implications.

## 6. Power

The system runs from a Mean Well LRS-350-12 (12 V, 29 A) wall supply. The key hazard is **regenerative braking**.

A switching supply can't sink current. When a motor decelerates a moving load, it pumps energy back onto the 12 V rail and the voltage rises. The BTS7960 has a 27 V limit, and exceeding it can destroy drivers. The hardware mitigation is a ~40,000 µF capacitor bank. If testing shows rail voltage climbing past ~18 V, a brake chopper is the escalation. Other protection: NTC inrush limiting, a fused IEC inlet with earth bonded to chassis, per-motor DC fusing, and a bleeder across the capacitor bank.

## 7. Control

The target is **impedance control at 1 kHz** on the ESP32. Compute is not the concern, at roughly 1-2 MFLOPs/sec. **Determinism is.** The risks are flash-cache stalls, FreeRTOS scheduling, and the radio core. A Teensy 4.1 is the fallback if jitter testing shows the ESP32 can't hold the loop timing.