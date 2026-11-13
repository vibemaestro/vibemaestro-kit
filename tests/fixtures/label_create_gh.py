#!/usr/bin/env python3
"""A fake `gh` for kit:label-create (tests/test-kit-label-create.sh): the two calls the kit makes, on a JSON world file.

Usage: label_create_gh.py <world.json> <log> <gh args...>

The world: {"labels": {"<owner/repo>": ["<name>", ...]}, "fail": ["<name>", ...]}. A repository not in "labels" answers 404.
`api --paginate repos/<r>/labels?per_page=100 --jq .[].name` prints its names, one per line, and logs `read <owner/repo>`. `api -X POST repos/<r>/labels -f
name=<n> --jq .name` is refused (422) when <r> has <n>, its case ignored, as GitHub refuses it, and fails (500) for a name in
"fail"; else it adds <n>, prints it and logs `create <owner/repo> <name>`; "then_add": {"<n>": "<m>"} adds <m> too, as
another hand would between two creates. Any other call exits 2.
"""
import json
import sys

world_path, log_path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
world = json.load(open(world_path))


def fail(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


if args[:3] == ["api", "--paginate", args[2] if len(args) > 2 else ""] and args[3:] == ["--jq", ".[].name"]:
    repo = args[2].split("?")[0][len("repos/"):-len("/labels")]
    if not args[2].startswith("repos/") or not args[2].endswith("/labels?per_page=100") or repo not in world["labels"]:
        fail("gh: Not Found (HTTP 404)")
    with open(log_path, "a") as f:
        f.write("read %s\n" % repo)
    for n in world["labels"][repo]:
        print(n)
elif args[:3] == ["api", "-X", "POST"] and len(args) == 8 and args[4] == "-f" and args[5].startswith("name=") and args[6:] == ["--jq", ".name"]:
    repo, name = args[3][len("repos/"):-len("/labels")], args[5][len("name="):]
    if repo not in world["labels"]:
        fail("gh: Not Found (HTTP 404)")
    if name.lower() in [n.lower() for n in world["labels"][repo]]:
        fail("gh: Validation Failed (HTTP 422): already_exists")
    if name in world.get("fail", []):
        fail("gh: Server Error (HTTP 500)")
    world["labels"][repo].append(name)
    if name in world.get("then_add", {}):
        world["labels"][repo].append(world["then_add"][name])
    json.dump(world, open(world_path, "w"))
    with open(log_path, "a") as f:
        f.write("create %s %s\n" % (repo, name))
    print(name)
else:
    fail("label_create_gh.py: unexpected call: %r" % (args,), 2)
