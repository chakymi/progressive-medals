"""Read-only verification that rank 5000 exists on all 25 Fall 2026 maps."""
import time

from publish_fall_2026 import load_roster
from world_rank_publisher import count_players


def main():
    roster = load_roster()
    counts = []
    for item in roster["maps"]:
        counts.append((item["number"], count_players(item["uid"])))
        time.sleep(2.5)  # No concurrent map/leaderboard requests.
    eligible = [number for number, count in counts if count >= 5000]
    waiting = [number for number, count in counts if count < 5000]
    print(f"Fall 2026: {len(eligible)}/25 maps have verified world rank 5000; "
          f"minimum reported player count={min(count for _, count in counts)}.")
    if waiting:
        print("Below threshold (map numbers only): " + ", ".join(str(number) for number in waiting))
    print("Read-only check; no medals captured or published.")


if __name__ == "__main__":
    main()
