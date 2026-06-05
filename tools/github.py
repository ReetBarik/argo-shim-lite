import asyncio
import os

from github import Auth, Github, GithubException

gh = Github(auth=Auth.Token(os.environ["GITHUB_TOKEN"]))

TOOLS = [
    {
        "name": "github_list_repos",
        "description": "List all GitHub repositories the bot has access to.",
        "input_schema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "github_read_file",
        "description": "Read a file from a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":  {"type": "string", "description": "owner/repo"},
                "path":  {"type": "string", "description": "File path in repo"},
                "ref":   {"type": "string", "description": "Branch, tag, or SHA (optional)"},
            },
            "required": ["repo", "path"],
        },
    },
    {
        "name": "github_list_files",
        "description": "List files and directories at a path in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo": {"type": "string", "description": "owner/repo"},
                "path": {"type": "string", "description": "Directory path (default: root)", "default": ""},
                "ref":  {"type": "string", "description": "Branch, tag, or SHA (optional)"},
            },
            "required": ["repo"],
        },
    },
    {
        "name": "github_write_file",
        "description": "Create or update a file in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":    {"type": "string", "description": "owner/repo"},
                "path":    {"type": "string"},
                "content": {"type": "string", "description": "Full file content"},
                "message": {"type": "string", "description": "Commit message"},
                "branch":  {"type": "string", "description": "Target branch (optional, defaults to repo default)"},
            },
            "required": ["repo", "path", "content", "message"],
        },
    },
    {
        "name": "github_create_issue",
        "description": "Create an issue in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":   {"type": "string", "description": "owner/repo"},
                "title":  {"type": "string"},
                "body":   {"type": "string"},
                "labels": {"type": "array", "items": {"type": "string"}},
            },
            "required": ["repo", "title", "body"],
        },
    },
    {
        "name": "github_create_pr",
        "description": "Create a pull request in a GitHub repository.",
        "input_schema": {
            "type": "object",
            "properties": {
                "repo":  {"type": "string", "description": "owner/repo"},
                "title": {"type": "string"},
                "body":  {"type": "string"},
                "head":  {"type": "string", "description": "Branch with changes"},
                "base":  {"type": "string", "description": "Target branch (optional, defaults to repo default)"},
            },
            "required": ["repo", "title", "body", "head"],
        },
    },
]


def _list_repos() -> str:
    repos = list(gh.get_user().get_repos(type="all"))
    if not repos:
        return "No repositories found."
    lines = [f"[{'private' if r.private else 'public'}] {r.full_name}" for r in repos]
    return "\n".join(lines)


def _read_file(repo: str, path: str, ref: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"ref": ref} if ref else {}
    return r.get_contents(path, **kwargs).decoded_content.decode()


def _list_files(repo: str, path: str = "", ref: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"ref": ref} if ref else {}
    contents = r.get_contents(path, **kwargs)
    return "\n".join(
        f"{'[dir] ' if c.type == 'dir' else '[file]'} {c.path}" for c in contents
    )


def _write_file(repo: str, path: str, content: str, message: str, branch: str = None) -> str:
    r = gh.get_repo(repo)
    kwargs = {"branch": branch} if branch else {}
    try:
        existing = r.get_contents(path, **kwargs)
        r.update_file(path, message, content, existing.sha, **kwargs)
        return f"Updated `{path}` in {repo}"
    except GithubException:
        r.create_file(path, message, content, **kwargs)
        return f"Created `{path}` in {repo}"


def _create_issue(repo: str, title: str, body: str, labels: list = None) -> str:
    r = gh.get_repo(repo)
    issue = r.create_issue(title=title, body=body, labels=labels or [])
    return f"Created issue #{issue.number}: {issue.html_url}"


def _create_pr(repo: str, title: str, body: str, head: str, base: str = None) -> str:
    r = gh.get_repo(repo)
    base = base or r.default_branch
    pr = r.create_pull(title=title, body=body, head=head, base=base)
    return f"Created PR #{pr.number}: {pr.html_url}"


def _wrap(fn):
    async def handler(**kwargs):
        return await asyncio.to_thread(fn, **kwargs)
    return handler


HANDLERS = {
    "github_list_repos":  _wrap(_list_repos),
    "github_read_file":   _wrap(_read_file),
    "github_list_files":  _wrap(_list_files),
    "github_write_file":  _wrap(_write_file),
    "github_create_issue": _wrap(_create_issue),
    "github_create_pr":   _wrap(_create_pr),
}
