#!/usr/bin/env -S just --justfile

set minimum-version := '1.55.0'

set default-list
set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Bootstrap Recipes
[group('Bootstrap')]
mod bootstrap "bootstrap"

# GitHub Recipes
[group('GitHub')]
mod gh ".just/github"

# Kube Recipes
[group('Kube')]
mod kube "kubernetes"

# Talos Recipes
[group('Talos')]
mod talos "talos"

# VolSync Recipes
[group('VolSync')]
mod volsync "kubernetes/components/volsync"

[private]
log lvl msg *args:
    printf '%s %s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject
