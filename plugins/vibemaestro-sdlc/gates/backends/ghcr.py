"""Registry backend `ghcr`: GitHub container packages, read through `gh api` (GET only; the token needs `read:packages`).

The image is `<owner>/<name>` without host or tag; `<name>` may hold `/`, sent as `%2F`. The owner is tried as an organisation,
then as a user. A package that is under neither has no tags and an `unknown` visibility. The real endpoints are *chưa kiểm*:
the suite runs on a fake `gh`.
"""
import urllib.parse

from backends import NotFound, api, api_pages

OWNER_KINDS = ("orgs", "users")
_BASE = {}


def _base(image):
    """`<orgs|users>/<owner>/packages/container/<name>` of the image, and the package object; (None, None) when absent."""
    if image in _BASE:
        return _BASE[image]
    owner, _sep, name = image.partition("/")
    pkg = urllib.parse.quote(name, safe="")
    found = (None, None)
    for kind in OWNER_KINDS:
        base = "%s/%s/packages/container/%s" % (kind, owner, pkg)
        try:
            found = (base, api(base))
            break
        except NotFound:
            continue
    _BASE[image] = found
    return found


def list_tags(image):
    base, _obj = _base(image)
    if base is None:
        return []
    tags = set()
    for page in api_pages(base + "/versions?per_page=100"):
        for v in page if isinstance(page, list) else []:
            tags.update(((v.get("metadata") or {}).get("container") or {}).get("tags") or [])
    return sorted(tags)


def tag_exists(image, tag):
    return tag in list_tags(image)


def visibility(image):
    _base_path, obj = _base(image)
    v = (obj or {}).get("visibility")
    return v if v in ("private", "public") else "unknown"
