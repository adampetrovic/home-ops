set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Selectively merge open GitHub PRs using fzf')]
merge method="rebase" delete_branch="true":
    case "{{ method }}" in
        merge|squash|rebase) ;;
        *) echo "method must be merge, squash, or rebase" >&2; exit 64 ;;
    esac
    case "{{ delete_branch }}" in
        true|false) ;;
        *) echo "delete_branch must be true or false" >&2; exit 64 ;;
    esac
    command -v gh >/dev/null
    command -v fzf >/dev/null
    gh auth status >/dev/null
    prs=$(gh pr list --state open --json number,title \
        --jq '.[] | "\(.number)\t\(.title)"' \
        | fzf --multi --header="SPACE select · ENTER merge · ESC cancel" \
              --bind='space:toggle' \
              --preview='gh pr diff {1} --color=always' \
              --preview-window=down:60%:wrap)
    [[ -z "${prs}" ]] && echo "No PRs selected." && exit 0
    count=$(printf '%s\n' "${prs}" | wc -l | tr -d ' ')
    echo "Merging ${count} PR(s) with --{{ method }}..."
    echo
    delete_flag=()
    if [[ "{{ delete_branch }}" == "true" ]]; then
        delete_flag=(--delete-branch)
    fi
    while IFS=$'\t' read -r pr title; do
        echo "→ #${pr} ${title}"
        if gh pr merge "${pr}" --{{ method }} "${delete_flag[@]}"; then
            echo "  ✓ merged"
        else
            echo "  ✗ failed"
        fi
    done <<< "${prs}"
