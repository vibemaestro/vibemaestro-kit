A dependent plugin for tests/test-gates.sh [D] [N]: it declares one gate, `demo`, in
`gates/install.json`. The suite copies it into a scratch plugin cache and registry and writes its manifest there (a dependency
on vibemaestro-sdlc); it ships none, so suites that read every manifest pass it by.
