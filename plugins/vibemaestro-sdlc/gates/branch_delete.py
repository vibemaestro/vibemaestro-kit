#!/usr/bin/env python3
"""The delete of the kit batons kit:branch-delete and kit:branch-delete-recoverable: one branch of a github.com repository,
deleted with a lease on its pinned SHA.

    branch_delete.py --repo <owner/name> --branch <name> --head <sha40> --url <push url> --plan <plan line> --expect-plan <file>

The kit proves the branch merged and builds the plan line; this gate is the only place its delete is written, run by the kit's
del() inside write(), so the kit's own text holds no delete. Before anything is pushed it checks that the plan line is a whole
line of the signed plan (--expect-plan, the BATON_PLAN baton hands the run) and that the line names exactly this delete:
`delete merged branch <branch> at <head> (…) on <url>` (kit:branch-delete), or `delete branch <branch> at <head> (kept in
bundle <path>) on <url>` (kit:branch-delete-recoverable). For the second, the bundle must be the regular file the kit names
under the baton state directory's bundles/ (no symlink), whose one head is `<head> refs/heads/<branch>` and which unbundles
into an empty repository with every object of <head>: the delete is not pushed unless the commits it removes are kept. The
URL is the repository's https or ssh github.com URL, the two forms the kit builds. The push runs from a new scratch bare repository, with the git settings and the allowlisted environment of
the kit's sgit() and cleanenv() (a test holds them equal): no config, hook or variable of the clone or the user reaches it. It
sends `:refs/heads/<branch>` with `--force-with-lease=refs/heads/<branch>:<head>`, so GitHub refuses it when the branch is not
at the pinned SHA any more.

Exit codes: 0 the push succeeded; 1 the push failed (the lease or the remote refused it, or its answer was lost: the caller
reads the remote to tell which); 3 refused before any push (the signed plan cannot be read, the plan line is not in it, it names another
delete, or its bundle does not hold the head);
64 bad usage, nothing pushed. Standard library and git only, Python 3.8+.
"""
import os, re, stat, subprocess, sys, tempfile

HOST = "github.com"
# the kit's sgit() settings, in its order
GIT_CONFIG = ("core.hooksPath=/dev/null", "protocol.allow=never", "protocol.https.allow=always", "protocol.ssh.allow=always",
              "http.sslVerify=true", "push.followTags=false", "push.recurseSubmodules=no", "submodule.recurse=false",
              "log.showSignature=false", "credential.helper=", "credential.helper=!gh auth git-credential")
# the kit's cleanenv(): the variables kept when set, then the fixed ones
ENV_KEEP = ("PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSH_AUTH_SOCK", "GIT_SSH_COMMAND", "GH_TOKEN", "GITHUB_TOKEN",
            "GH_ENTERPRISE_TOKEN", "GH_HOST", "GH_CONFIG_DIR", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "NO_PROXY",
            "no_proxy", "ALL_PROXY", "all_proxy")
ENV_FIXED = (("GIT_CONFIG_NOSYSTEM", "1"), ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_TERMINAL_PROMPT", "0"), ("GIT_PAGER", "cat"))
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
PLAN = re.compile(r"delete merged branch (\S+) at ([0-9a-f]{40}) \(.*\) on (\S+)\Z")
KEPT = re.compile(r"delete branch (\S+) at ([0-9a-f]{40}) \(kept in bundle (/\S+)\) on (\S+)\Z")
FLAGS = ("--repo", "--branch", "--head", "--url", "--plan", "--expect-plan")
USAGE = "usage: branch_delete.py " + " ".join("%s <%s>" % (f, f[2:]) for f in FLAGS)


class Args:
    pass


def say(msg, out=sys.stderr):
    out.write(msg + "\n")
    out.flush()


def env():
    e = dict((k, os.environ[k]) for k in ENV_KEEP if k in os.environ)
    e.update(ENV_FIXED)
    return e


def git(args, **kw):
    return subprocess.run(["git"] + args, env=env(), stdin=subprocess.DEVNULL, **kw).returncode


def branchname(b):
    """The kit's branchname(): letters, digits and ._/-, what git check-ref-format takes, minus the names git resolves first as
    another ref."""
    first = b.split("/", 1)[0]
    return (re.match(r"[A-Za-z0-9._/-]+\Z", b) is not None and not b.startswith("-")
            and re.match(r"(?:HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV)\Z", b) is None
            and first not in ("refs", "heads", "tags", "remotes") and re.match(r"[0-9a-fA-F]{40}\Z", b) is None
            and git(["check-ref-format", "refs/heads/" + b], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0)


def parse(argv):
    """Args, or None (after saying why) when the arguments are not the six flags, each once with a value this gate takes."""
    a, seen = Args(), {}
    if len(argv) != 2 * len(FLAGS):
        say(USAGE)
        return None
    for i in range(0, len(argv), 2):
        f, v = argv[i], argv[i + 1]
        if f not in FLAGS or f in seen:
            say(USAGE)
            return None
        seen[f] = v
    a.repo, a.branch, a.head, a.url, a.plan, a.expect = (seen[f] for f in FLAGS)
    urls = ("https://%s/%s.git" % (HOST, a.repo), "git@%s:%s.git" % (HOST, a.repo))
    if not REPO.match(a.repo) or not branchname(a.branch) or not SHA.match(a.head) or "\n" in a.plan or not a.expect:
        say("REFUSE an argument this gate does not take (repo, branch, head, plan or signed plan): nothing pushed")
        return None
    if a.url not in urls:
        say("REFUSE %s is not %s or %s: nothing pushed" % (a.url, urls[0], urls[1]))
        return None
    return a


def state_base():
    """The baton state directory's base, as baton and the kits compute it."""
    x = os.environ.get("XDG_STATE_HOME", "")
    return x if x.startswith("/") else os.path.join(os.environ.get("HOME", ""), ".local", "state")


def bundle_problem(path, branch, head, scratch):
    """Why the bundle at path does not keep head as refs/heads/<branch>, or None."""
    bundles = os.path.join(state_base(), "vibemaestro", "baton", "bundles")
    want = "kit-branch-delete-recoverable-%s-%s.bundle"
    name = os.path.basename(path)
    if (os.path.normpath(os.path.dirname(path)) != os.path.normpath(bundles) or re.match(want % ("[0-9a-f]{16}", head) + r"\Z", name) is None
            or os.path.realpath(os.path.dirname(path)) != os.path.realpath(bundles)):
        return "%s is not a bundle of this head under %s" % (path, bundles)
    try:
        if not stat.S_ISREG(os.lstat(path).st_mode):
            return "%s is not a regular file" % path
    except OSError as e:
        return "%s cannot be read (%s)" % (path, e.strerror)
    v = os.path.join(scratch, "verify.git")
    git(["init", "-q", "--bare", "--template=", v])
    heads = subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", v, "bundle", "list-heads", path], env=env(),
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if heads.returncode != 0 or heads.stdout != "%s refs/heads/%s\n" % (head, branch):
        return "the bundle %s does not hold exactly %s refs/heads/%s" % (path, head, branch)
    quiet = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if (git(["-c", "core.hooksPath=/dev/null", "-C", v, "bundle", "unbundle", path], **quiet) != 0
            or git(["-C", v, "rev-list", "--objects", "--missing=error", head], **quiet) != 0):
        return "the bundle %s does not hold every object of %s" % (path, head)
    return None


def main(argv):
    a = parse(argv)
    if a is None:
        return 64
    try:
        with open(a.expect, encoding="utf-8", errors="surrogateescape") as f:
            signed = f.read().split("\n")
    except OSError as e:
        say("REFUSE the signed plan %s cannot be read (%s): nothing pushed" % (a.expect, e.strerror))
        return 3
    plan = a.plan
    if plan not in signed:
        say("REFUSE the delete line is not in the signed plan (the branch or base moved since signing): nothing pushed")
        return 3
    m, k = PLAN.match(plan), KEPT.match(plan)
    if not (m and m.group(1, 2, 3) == (a.branch, a.head, a.url) or k and k.group(1, 2, 4) == (a.branch, a.head, a.url)):
        say("REFUSE the signed line does not name this delete (%s at %s on %s): nothing pushed" % (a.branch, a.head, a.url))
        return 3
    with tempfile.TemporaryDirectory(prefix="kit-branch-delete-gate.") as d:
        why = bundle_problem(k.group(3), a.branch, a.head, d) if k else None
        if why:
            say("REFUSE %s: nothing pushed" % why)
            return 3
        repo = os.path.join(d, "repo.git")
        if git(["init", "-q", "--bare", "--template=", repo]) != 0:
            say("the scratch repository cannot be made: nothing pushed")
            return 1
        cfg = []
        for c in GIT_CONFIG:
            cfg += ["-c", c]
        rc = git(cfg + ["-C", repo, "push", "-q", "--force-with-lease=refs/heads/%s:%s" % (a.branch, a.head), a.url,
                        ":refs/heads/" + a.branch])
    if rc != 0:
        say("the push of the delete failed (git rc %d)" % rc)
        return 1
    say("deleted refs/heads/%s at %s on %s" % (a.branch, a.head, a.url), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
