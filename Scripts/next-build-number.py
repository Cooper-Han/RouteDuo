"""Reserve a monotonically increasing Shanghai-date build number before packaging."""
from datetime import datetime, timedelta
from pathlib import Path
import re
from zoneinfo import ZoneInfo


def next_build(previous: int, day: str) -> int:
    floor = int(day + "01")
    if previous < floor:
        return floor
    previous_text = str(previous)
    if len(previous_text) != 10 or not 1 <= int(previous_text[-2:]) <= 99:
        raise ValueError("已有构建号格式不合法，无法自动递增")
    if int(previous_text[-2:]) == 99:
        raise ValueError("当天已使用 99 个构建号，请在下一天继续打包")
    return previous + 1


if __name__ == "__main__":
    project = Path(__file__).resolve().parents[1] / "WorkRouteMenu.xcodeproj/project.pbxproj"
    source = project.read_text()
    values = re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", source)
    if not values:
        raise SystemExit("未找到构建号")
    day = datetime.now(ZoneInfo("Asia/Shanghai")).strftime("%Y%m%d")
    number = next_build(max(map(int, values)), day)
    project.write_text(re.sub(r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {number};", source))
    print(number)
