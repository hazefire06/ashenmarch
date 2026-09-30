#!/usr/bin/env python3
"""Prints FixedMath.SIN_QUARTER, the quarter-wave sine table sim/ uses for
integer trig. Run this and paste the output into sim/fixed_math.gd if
ANGLE_FULL or TRIG_ONE ever change.

The table is generated offline so the sim never calls sin(): libm results
differ in the last bit between platforms, which is enough to desync
lockstep peers once rounded.
"""

import math

ANGLE_FULL = 1024  # binary angle units per turn (FixedMath.ANGLE_FULL)
TRIG_ONE = 65536  # fixed-point 1.0 (FixedMath.TRIG_ONE)
PER_ROW = 12


def main() -> None:
    quarter = ANGLE_FULL // 4
    values = [
        round(math.sin(k * 2.0 * math.pi / ANGLE_FULL) * TRIG_ONE)
        for k in range(quarter + 1)
    ]
    rows = [
        ", ".join(str(v) for v in values[i : i + PER_ROW])
        for i in range(0, len(values), PER_ROW)
    ]
    print("const SIN_QUARTER: Array[int] = [")
    for row in rows:
        print(f"\t{row},")
    print("]")


if __name__ == "__main__":
    main()
