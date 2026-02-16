#!/bin/bash
# Build script for Achaeadex Ledger
# Runs tests and builds muddler package

set -e

echo "==> Setting up Lua 5.1 environment..."
eval "$(luarocks --lua-version 5.1 path)"

echo "==> Running busted tests..."
busted --verbose

echo "==> All tests passed!"

echo "==> Building .mpackage with muddler..."
muddler

mkdir -p build
if ls *.mpackage >/dev/null 2>&1; then
	mv -f *.mpackage build/
fi

echo "==> Build complete!"
