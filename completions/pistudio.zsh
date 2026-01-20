#compdef pistudio
# Zsh completion for pistudio
# Source this file or add to fpath:
#   fpath=(/path/to/completions $fpath) && compinit
#
# Or source directly:
#   source /path/to/completions/pistudio.zsh

_pistudio() {
    local -a commands subcommands
    commands=(
        'login:Authenticate via browser SSO'
        'logout:Sign out'
        'status:Show auth status and current profile'
        'doctor:Run preflight checks'
        'envs:List Power Platform environments'
        'copilot:Copilot commands (list, get, create, remove, restore)'
        'bots:List Copilot Studio bots'
        'agents:Manage sub-agents'
        'convs:Conversations (list, export, search, watch)'
        'transcripts:Dataverse transcripts (list, export)'
        'open:Open in Copilot Studio browser'
        'analytics:Regenerate analytics from existing export'
        'export:Export conversation (shortcut)'
        'search:Search conversations (shortcut)'
        'watch:Watch conversation (shortcut)'
    )

    local -a global_opts
    global_opts=(
        '(-p --profile)'{-p,--profile}'[Config profile]:profile:_pistudio_profiles'
        '(-b --bot-id)'{-b,--bot-id}'[Bot schema name]:bot:'
        '(-v --verbose)'{-v,--verbose}'[Debug output]'
        '--debug[Debug output (M365-compatible)]'
        '(-d --days)'{-d,--days}'[Filter to last N days]:days:'
        '(-o --output)'{-o,--output}'[Output directory or format]:output:_files -/'
        '--dry-run[Print command without executing]'
        '--i-know-this-is-prod[Allow writes for protected profiles]'
        '--help[Show help]'
    )

    _arguments -C \
        $global_opts \
        '1:command:->command' \
        '*::arg:->args'

    case "$state" in
        command)
            _describe 'command' commands
            ;;
        args)
            local cmd="${words[1]}"
            case "$cmd" in
                envs)
                    subcommands=(
                        'details:Show environment details'
                        'flags:Show feature flags'
                    )
                    _arguments -C \
                        $global_opts \
                        '--env-id[Environment ID]:env-id:' \
                        '1:subcommand:->envs_sub'
                    [[ "$state" == envs_sub ]] && _describe 'subcommand' subcommands
                    ;;
                copilot)
                    subcommands=(
                        'list:List copilots'
                        'get:Get copilot details'
                        'create:Create new copilot'
                        'remove:Delete copilot'
                        'restore:Restore copilot from backup'
                    )
                    _arguments -C \
                        $global_opts \
                        '--id[Copilot ID]:id:' \
                        '--name[Copilot name]:name:' \
                        '--schema[Schema name]:schema:' \
                        '--from-backup[Backup directory]:dir:_files -/' \
                        '--yes-really-delete[Confirm deletion]' \
                        '--confirm[Confirm value]:confirm:' \
                        '--as-admin[Run as admin]' \
                        '--env-id[Environment ID]:env-id:' \
                        '1:subcommand:->copilot_sub'
                    [[ "$state" == copilot_sub ]] && _describe 'subcommand' subcommands
                    ;;
                bots)
                    _arguments $global_opts '--env-id[Environment ID]:env-id:'
                    ;;
                agents)
                    subcommands=(
                        'get:Export agent config to YAML'
                        'create:Create new agent'
                        'update:Update agent field'
                        'delete:Delete agent'
                        'clone:Clone agent'
                        'diff:Compare two agents'
                        'backup:Backup all agents'
                        'restore:Restore from backup'
                    )
                    _arguments -C \
                        $global_opts \
                        '--yaml-file[YAML config file]:file:_files' \
                        '--field[Field to update]:field:(data description name)' \
                        '--value[New value]:value:' \
                        '--yes-really-delete[Confirm deletion]' \
                        '--confirm[Confirm value]:confirm:' \
                        '--name[Agent name]:name:' \
                        '--dir[Backup directory]:dir:_files -/' \
                        '--backup-dir[Backup directory]:dir:_files -/' \
                        '1:subcommand:->agents_sub' \
                        '2:agent:'
                    [[ "$state" == agents_sub ]] && _describe 'subcommand' subcommands
                    ;;
                convs)
                    subcommands=(
                        'export:Export conversation'
                        'search:Search conversations'
                        'watch:Watch live conversation'
                    )
                    _arguments -C \
                        $global_opts \
                        '--all[Export all conversations]' \
                        '--file[Conversations file]:file:_files' \
                        '--interval[Watch interval]:seconds:' \
                        '1:subcommand:->convs_sub'
                    [[ "$state" == convs_sub ]] && _describe 'subcommand' subcommands
                    ;;
                transcripts)
                    subcommands=(
                        'export:Export transcript'
                    )
                    _arguments -C \
                        $global_opts \
                        '--bot-guid[Bot GUID]:guid:' \
                        '--transcript-id[Transcript ID]:id:' \
                        '1:subcommand:->trans_sub'
                    [[ "$state" == trans_sub ]] && _describe 'subcommand' subcommands
                    ;;
                login|logout)
                    _arguments $global_opts '--device-code[Use device code flow]'
                    ;;
                status|doctor)
                    _arguments $global_opts
                    ;;
                open)
                    _arguments $global_opts '--url[Copilot Studio URL]:url:' '--env-id[Environment ID]:env-id:'
                    ;;
                analytics)
                    _arguments $global_opts '1:directory:_files -/'
                    ;;
                export|watch)
                    _arguments $global_opts '1:conversation-id:'
                    ;;
                search)
                    _arguments $global_opts '1:search-term:'
                    ;;
            esac
            ;;
    esac
}

_pistudio_profiles() {
    local config_file="${PISTUDIO_CONFIG_FILE:-./config/copilot-export.json}"
    if [[ -f "$config_file" ]] && command -v jq &>/dev/null; then
        local -a profiles
        profiles=(${(f)"$(jq -r '.profiles | keys[]' "$config_file" 2>/dev/null)"})
        _describe 'profile' profiles
    fi
}

_pistudio "$@"
