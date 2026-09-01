from __future__ import annotations

import http.cookiejar
import sys
from pathlib import Path

import browser_cookie3


COOKIE_SOURCES = [
    (
        "FFDL Winport",
        browser_cookie3.chrome,
        {
            "cookie_file": str(
                Path.home()
                / "AppData"
                / "Local"
                / "fanficdownloader"
                / "QtWebEngine"
                / "Default"
                / "Cookies"
            )
        },
    ),
    ("Chrome", browser_cookie3.chrome, {}),
    ("Edge", browser_cookie3.edge, {}),
]


def main() -> int:
    default_output = Path(__file__).resolve().parent / "user" / "fanfiction-net-cookies.txt"
    output = Path(sys.argv[1]) if len(sys.argv) > 1 else default_output
    moz = http.cookiejar.MozillaCookieJar(str(output))
    count = 0

    for name, loader, kwargs in COOKIE_SOURCES:
        try:
            jar = loader(domain_name="fanfiction.net", **kwargs)
        except Exception as exc:
            print(f"Skipped {name}: {exc}", file=sys.stderr)
            continue

        source_count = 0
        for cookie in jar:
            if "fanfiction.net" in cookie.domain:
                moz.set_cookie(cookie)
                count += 1
                source_count += 1
        print(f"Found {source_count} fanfiction.net cookies from {name}")

    output.parent.mkdir(parents=True, exist_ok=True)
    moz.save(str(output), ignore_discard=True, ignore_expires=True)
    print(f"Exported {count} fanfiction.net cookies to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
