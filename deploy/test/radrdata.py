"""Made-up watch summaries for the RADR checks in security.py and smoke.py: seven ordinary weeks,
then a week of short, late sleep, fewer steps and a higher resting heart rate, so that several
RADR domains are away from usual on the latest day. Standard library only.
SPDX-License-Identifier: AGPL-3.0-or-later
"""
import datetime


def days(today=None, n=56, changed=8):
    """n days ending today (oldest first), the last `changed` of them away from usual."""
    today = today or datetime.date.today()
    out = []
    for back in range(n - 1, -1, -1):
        i = n - 1 - back
        wobble = (i * 7) % 5 - 2          # -2..2, the same every run
        away = back < changed
        out.append({"day": (today - datetime.timedelta(days=back)).isoformat(), "values": {
            "sleep_min": (300 if away else 420) + 6 * wobble,
            "sleep_onset": (75 if away else -30) + 5 * wobble,
            "sleep_wake": (375 if away else 390) + 4 * wobble,
            "steps": (3000 if away else 8000) + 300 * wobble,
            "rhr": (68 if away else 60) + 0.5 * wobble,
            "rhr_method": "sleep",
        }})
    return out
