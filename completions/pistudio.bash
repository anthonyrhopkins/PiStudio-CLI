# Bash completion for pistudio
# Source this file or add to ~/.bashrc:
#   source /path/to/completions/pistudio.bash
#
# Or copy to system completions:
#   cp completions/pistudio.bash /usr/local/etc/bash_completion.d/pistudio

_pistudio_completions() {
    local cur prev words cword
    _init_completion || return

    local commands="login logout status doctor envs copilot bots agents convs transcripts open analytics export search watch"

    local global_flags="-p --profile -b --bot-id -v --verbose --debug -d --days -o --output --dry-run --i-know-this-is-prod --help"

    # Find the subcommand (first non-flag word after pistudio)
    local subcmd="" subcmd_idx=0
    for ((i=1; i < cword; i++)); do
        case "${words[i]}" in
            -p|--profile|-b|--bot-id|-d|--days|-o|--output)
                ((i++))  # skip the value
                ;;
            -*)
                ;;
            *)
                if [[ -z "$subcmd" ]]; then
                    subcmd="${words[i]}"
                    subcmd_idx=$i
                fi
                ;;
        esac
    done

    # Find the sub-subcommand (second non-flag word)
    local subverb=""
    for ((i=subcmd_idx+1; i < cword; i++)); do
        case "${words[i]}" in
            -p|--profile|-b|--bot-id|-d|--days|-o|--output|--field|--value|--yaml-file|--dir|--name|--schema|--confirm|--interval|--env-id|--from-backup|--id)
                ((i++))
                ;;
            -*)
                ;;
            *)
                if [[ -z "$subverb" ]]; then
                    subverb="${words[i]}"
                fi
                ;;
        esac
    done

    # Complete based on context
    case "$prev" in
        -p|--profile)
            # Complete profile names from config
            local config_file="${PISTUDIO_CONFIG_FILE:-./config/copilot-export.json}"
            if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
                local profiles
                profiles=$(jq -r '.profiles | keys[]' "$config_file" 2>/dev/null)
                COMPREPLY=($(compgen -W "$profiles" -- "$cur"))
            fi
            return
            ;;
        --field)
            COMPREPLY=($(compgen -W "data description name" -- "$cur"))
            return
            ;;
        --yaml-file|--config|--from-backup|--dir|--backup-dir)
            _filedir
            return
            ;;
        -o|--output)
            case "$subcmd" in
                copilot)
                    COMPREPLY=($(compgen -W "json text csv md none" -- "$cur"))
                    return
                    ;;
                *)
                    _filedir -d
                    return
                    ;;
            esac
            ;;
        -f|--format)
            COMPREPLY=($(compgen -W "json csv html md" -- "$cur"))
            return
            ;;
    esac

    # No subcommand yet — complete commands
    if [[ -z "$subcmd" ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$commands" -- "$cur"))
        fi
        return
    fi

    # Complete sub-subcommands and flags per command
    case "$subcmd" in
        envs)
            if [[ -z "$subverb" && "$cur" != -* ]]; then
                COMPREPLY=($(compgen -W "details flags" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_flags --env-id" -- "$cur"))
            fi
            ;;
        copilot)
            if [[ -z "$subverb" && "$cur" != -* ]]; then
                COMPREPLY=($(compgen -W "list get create remove restore" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_flags --id --name --schema --as-admin --from-backup --yes-really-delete --confirm --env-id --query" -- "$cur"))
            fi
            ;;
        bots)
            COMPREPLY=($(compgen -W "$global_flags --env-id" -- "$cur"))
            ;;
        agents)
            if [[ -z "$subverb" && "$cur" != -* ]]; then
                COMPREPLY=($(compgen -W "get create update delete clone diff backup restore" -- "$cur"))
            else
                case "$subverb" in
                    create)
                        COMPREPLY=($(compgen -W "$global_flags --yaml-file" -- "$cur"))
                        ;;
                    update)
                        COMPREPLY=($(compgen -W "$global_flags --field --value --yaml-file" -- "$cur"))
                        ;;
                    delete)
                        COMPREPLY=($(compgen -W "$global_flags --yes-really-delete --confirm" -- "$cur"))
                        ;;
                    clone)
                        COMPREPLY=($(compgen -W "$global_flags --name" -- "$cur"))
                        ;;
                    backup)
                        COMPREPLY=($(compgen -W "$global_flags --backup-dir" -- "$cur"))
                        ;;
                    restore)
                        COMPREPLY=($(compgen -W "$global_flags --dir" -- "$cur"))
                        ;;
                    *)
                        COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        convs)
            if [[ -z "$subverb" && "$cur" != -* ]]; then
                COMPREPLY=($(compgen -W "export search watch" -- "$cur"))
            else
                case "$subverb" in
                    export)
                        COMPREPLY=($(compgen -W "$global_flags --all --file" -- "$cur"))
                        ;;
                    watch)
                        COMPREPLY=($(compgen -W "$global_flags --interval" -- "$cur"))
                        ;;
                    *)
                        COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
                        ;;
                esac
            fi
            ;;
        transcripts)
            if [[ -z "$subverb" && "$cur" != -* ]]; then
                COMPREPLY=($(compgen -W "export" -- "$cur"))
            else
                COMPREPLY=($(compgen -W "$global_flags --bot-guid --transcript-id" -- "$cur"))
            fi
            ;;
        login|logout|status|doctor)
            COMPREPLY=($(compgen -W "$global_flags --device-code" -- "$cur"))
            ;;
        open)
            COMPREPLY=($(compgen -W "$global_flags --url --env-id" -- "$cur"))
            ;;
        analytics)
            _filedir -d
            ;;
        export)
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
            ;;
        search)
            COMPREPLY=($(compgen -W "$global_flags" -- "$cur"))
            ;;
        watch)
            COMPREPLY=($(compgen -W "$global_flags --interval" -- "$cur"))
            ;;
    esac
}

complete -F _pistudio_completions pistudio
