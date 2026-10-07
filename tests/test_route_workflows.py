import route_workflows as rw

WORKFLOW = """name: CI
on: [push]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v6
        with:
          node-version: 22
          cache: npm
  win:
    runs-on: 'windows-latest'  # comment stays
    steps:
      - uses: actions/setup-java@v6
        with: { distribution: 'temurin', java-version: '21', cache: 'maven' }
  mac:
    runs-on: macos-latest
"""


def test_routes_runs_on_and_gates_cache():
    text, n_runs, n_cache, notes = rw.route_text(WORKFLOW)
    assert n_runs == 2 and n_cache == 2
    assert "fromJSON('[\"self-hosted\",\"Linux\"]') || 'ubuntu-latest'" in text
    assert "fromJSON('[\"self-hosted\",\"Windows\"]') || 'windows-latest' }}  # comment stays" in text
    assert "cache: \"${{ vars.CI_RUNNER != 'local' && 'npm' || '' }}\"" in text
    # flow mapping keeps valid YAML: the expression is quoted
    assert "java-version: '21', cache: \"${{ vars.CI_RUNNER != 'local' && 'maven' || '' }}\" }" in text
    assert "runs-on: macos-latest" in text
    assert any("pinned image" in n for n in notes)


def test_idempotent():
    once = rw.route_text(WORKFLOW)[0]
    twice, n_runs, n_cache, _ = rw.route_text(once)
    assert twice == once and n_runs == 0 and n_cache == 0


def test_matrix_and_container_are_flagged(tmp_path):
    text = "jobs:\n  a:\n    runs-on: ${{ matrix.os }}\n    container: node:22\n"
    _, n_runs, _, notes = rw.route_text(text)
    assert n_runs == 0
    assert any("matrix" in n for n in notes) and any("container" in n for n in notes)


def test_preserves_crlf(tmp_path, monkeypatch, capsys):
    wf = tmp_path / ".github" / "workflows"
    wf.mkdir(parents=True)
    (wf / "ci.yml").write_bytes(WORKFLOW.replace("\n", "\r\n").encode())
    monkeypatch.setattr("sys.argv", ["route_workflows.py", str(tmp_path)])
    rw.main()
    raw = (wf / "ci.yml").read_bytes()
    assert b"\r\n" in raw and b"\n" not in raw.replace(b"\r\n", b"")
