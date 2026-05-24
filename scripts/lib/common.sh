#!/usr/bin/env bash
set -Eeuo pipefail

function log_level_priority() {
    case "${1:-info}" in
        debug) echo 1 ;;
        info) echo 2 ;;
        warn) echo 3 ;;
        error) echo 4 ;;
        *) echo 2 ;;
    esac
}

function log_level_color() {
    case "${1:-info}" in
        debug) printf "\\033[1m\\033[38;5;63m" ;;  # Blue
        warn) printf "\\033[1m\\033[38;5;192m" ;;  # Yellow
        error) printf "\\033[1m\\033[38;5;198m" ;; # Red
        info|*) printf "\\033[1m\\033[38;5;87m" ;; # Cyan
    esac
}

# Log messages with different levels. Keep this Bash 3 compatible for macOS
# recovery workstations, so avoid associative arrays.
function log() {
    local level="${1:-info}"
    shift || true

    local current_priority
    current_priority="$(log_level_priority "${level}")"

    local configured_level="${LOG_LEVEL:-info}"
    local configured_priority
    configured_priority="$(log_level_priority "${configured_level}")"

    # Skip log messages below the configured log level
    if ((current_priority < configured_priority)); then
        return
    fi

    local color
    color="$(log_level_color "${level}")"
    local msg="${1:-}"
    shift || true

    # Prepare additional data
    local data=
    if [[ $# -gt 0 ]]; then
        for item in "$@"; do
            if [[ "${item}" == *=* ]]; then
                data+="\033[1m\033[38;5;236m${item%%=*}=\033[0m\"${item#*=}\" "
            else
                data+="${item} "
            fi
        done
    fi

    # Determine output stream based on log level
    local output_stream="/dev/stdout"
    if [[ "$level" == "error" ]]; then
        output_stream="/dev/stderr"
    fi

    local upper_level
    upper_level="$(printf "%s" "${level}" | tr "[:lower:]" "[:upper:]")"

    # Print the log message
    printf "%s %b%s%b %s %b\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        "${color}" "${upper_level}" "\033[0m" "${msg}" "${data}" >"${output_stream}"

    # Exit if the log level is error
    if [[ "$level" == "error" ]]; then
        exit 1
    fi
}

# Check if required environment variables are set
function check_env() {
    local envs=("${@}")
    local missing=()
    local values=()

    for env in "${envs[@]}"; do
        if [[ -z "${!env-}" ]]; then
            missing+=("${env}")
        else
            values+=("${env}=${!env}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required env variables" "envs=${missing[*]}"
    fi

    log debug "Env variables are set" "envs=${values[*]}"
}

# Check if required CLI tools are installed
function check_cli() {
    local deps=("${@}")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "${dep}" &>/dev/null; then
            missing+=("${dep}")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        log error "Missing required deps" "deps=${missing[*]}"
    fi

    log debug "Deps are installed" "deps=${deps[*]}"
}

# Render a template using op to inject secrets
function render_template() {
    local -r file="${1}"
    local output

    if [[ ! -f "${file}" ]]; then
        log error "File does not exist" "file=${file}"
    fi

    if ! output=$(op inject -i "${file}" 2>/dev/null) || [[ -z "${output}" ]]; then
        log error "Failed to render config" "file=${file}"
    fi

    echo "${output}"
}
