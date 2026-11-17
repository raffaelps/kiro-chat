#!/usr/bin/env bash
# Publica uma versão nova: atualiza VERSION, faz o commit, cria a tag vX.Y.Z e envia para o GitHub.
# O GitHub Actions compila o app e cria a release com o KiroChat.zip (.github/workflows/release.yml).
# Uso: scripts/release.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."
NEW="${1:-}"
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Uso: scripts/release.sh X.Y.Z   (versão atual: $(cat VERSION))" >&2
    exit 2
fi
TAG="v$NEW"

[[ "$(git branch --show-current)" == "main" ]] || { echo "Faça a release a partir da main." >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Há mudanças não commitadas. Commite ou descarte antes." >&2; exit 1; }
git fetch -q origin main --tags
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "A main local não está igual à origin/main." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "A tag $TAG já existe." >&2; exit 1; fi

CURRENT="$(tr -d '[:space:]' < VERSION)"
# A versão nova tem de ser maior que a atual (o app só atualiza para versões maiores).
# Igual só vale quando o VERSION já foi atualizado e falta a tag (ex.: a primeira release).
if [[ "$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -V | tail -1)" != "$NEW" ]]; then
    echo "A versão nova ($NEW) precisa ser maior que a atual ($CURRENT)." >&2
    exit 1
fi

swift test

if [[ "$CURRENT" != "$NEW" ]]; then
    echo "$NEW" > VERSION
    git add VERSION
    git commit -q -m "Versão $NEW"
fi
git tag -a "$TAG" -m "Kiro Chat $NEW"
git push -q origin main "$TAG"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo raffaelps/kiro-chat)"
echo "✅ $TAG enviada. O GitHub Actions vai compilar e publicar a release em alguns minutos:"
echo "   https://github.com/$REPO/actions"
echo "   https://github.com/$REPO/releases/tag/$TAG"
