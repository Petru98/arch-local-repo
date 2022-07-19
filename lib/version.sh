# shellcheck shell=sh
ARCHURL='https://www.archlinux.org/packages/search/json'
AURURL='https://aur.archlinux.org/rpc'
VERFILTER='rc beta alpha'

verfilter() {
    set -f
    # shellcheck disable=SC2046 disable=SC2086
    grep -vF $(printf -- '-e %s ' ${*:-$VERFILTER})
    set +f
}
verfix() {
    tr '-' '.'
}

archlinux_version_url() {
    if [ "$#" != 2 ]; then
        echo "error: invalid number of arguments for archlinux_version_url" >&2
        return 1
    fi
    _url="$1"
    _args="name=$2"
    curl -sL "$_url/?$_args&repo=Core&repo=Extra&repo=Multilib&repo=Community" | jq -r '.results[] | .pkgver + "-" + .pkgrel'
    unset _url _args
}
archlinux_version() {
    if [ "$#" != 1 ]; then
        echo "error: invalid number of arguments for archlinux_version" >&2
        return 1
    fi
    archlinux_version_url "$ARCHURL" "$@"
}

# Each IP address has a limit of 4000 requests per day (https://wiki.archlinux.org/index.php/Aurweb_RPC_interface)
aur_version_url() {
    _url="$1"
    shift
    _args="arg[]=$(echo "$@" | sed -E 's/ /\&arg[]=/g')"
    curl -sL "$_url/?v=5&type=info&$_args" | jq -r '.results[].Version'
    unset _url _args
}
aur_version() {
    aur_version_url "$AURURL" "$@"
}

github_tags() {
    _project="$1"
    _regex="${2:-v?([[:alnum:]._-]+)}"
    curl -sL "https://github.com/$_project/tags" | sed -En "s|.*/archive/refs/tags/$_regex\\.tar\\.gz.*|\\1|p"
    unset _project _regex
}
gitlab_tags() {
    _url="$1"
    _regex="${2:-v?([[:alnum:]._-]+)}"
    curl -sL "$_url/tags" | sed -En "s|.*/archive/$_regex/[^/]+\\.tar\\.gz.*|\\1|p" | uniq
    unset _url _regex
}
codeberg_releases() {
    _project="$1"
    _regex="${2:-v?([[:alnum:]._-]+)}"
    curl -sL "https://codeberg.org/$_project/releases" | sed -En "s|.*/archive/$_regex\\.tar\\.gz.*|\\1|p"
    unset _project _regex
}
