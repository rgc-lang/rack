# main.rg — rack entry point: command dispatch
#
# rack is an RGC package manager written in RGC (a mini cargo).
# The project directory is the current working directory; the managed project layout is:
#   rack.toml / rack.lock / main.rg / *.rg / target/{deps,build,bin}

import cmds
import registry
import selfmgmt

def main() -> int {
    argv = args()
    if argv.len() < 2 {
        return cmd_help()
    }
    cmd = argv.get(1)

    if cmd == "help" or cmd == "--help" or cmd == "-h" {
        return cmd_help()
    }
    if cmd == "--version" or cmd == "version" {
        print("rack 0.4.2 (RGC)")
        return 0
    }
    if cmd == "new" {
        if argv.len() < 3 {
            print("error: rack new <name>")
            return 1
        }
        return cmd_new(argv.get(2))
    }
    if cmd == "init" {
        name = ""
        if argv.len() > 2 {
            name = argv.get(2)
        }
        return cmd_init(name)
    }
    if cmd == "build" {
        return cmd_build(".")
    }
    if cmd == "run" {
        rest = List[str]()
        i = 2
        if argv.len() > 2 and argv.get(2) == "--" {
            i = 3
        }
        while i < argv.len() {
            rest.push(argv.get(i))
            i = i + 1
        }
        return cmd_run(".", @rest)
    }
    if cmd == "test" {
        return cmd_test(@argv)
    }
    if cmd == "install" {
        # No argument: install every manifest dependency (keeping pinned versions).
        spec = ""
        if argv.len() >= 3 {
            spec = argv.get(2)
        }
        return cmd_install(".", spec)
    }
    if cmd == "update" {
        return cmd_update(".")
    }
    if cmd == "remove" {
        if argv.len() < 3 {
            print("error: rack remove <pkg>")
            return 1
        }
        return cmd_remove(".", argv.get(2))
    }
    if cmd == "tree" {
        return cmd_tree(".")
    }
    if cmd == "list" {
        return cmd_list(".")
    }
    if cmd == "publish" {
        return cmd_publish(".")
    }
    if cmd == "login" {
        # rack login                    → Device Flow：自动打开 /device 并轮询确认（§10）
        # rack login --code <code>      → fallback：/cli/login 页面的一次性 code 换 token
        # rack login --token <token>    → 手动粘贴 token
        if argv.len() == 2 {
            return cmd_login_browser()
        }
        if argv.len() == 4 and argv.get(2) == "--code" {
            return cmd_login_code(argv.get(3))
        }
        if argv.len() == 4 and argv.get(2) == "--token" {
            return cmd_login(argv.get(3))
        }
        print("error: rack login [--code <code> | --token <token>]")
        return 1
    }
    if cmd == "logout" {
        return cmd_logout()
    }
    if cmd == "yank" {
        if argv.len() < 3 {
            print("error: rack yank <scope>/<name>@<version>")
            return 1
        }
        return cmd_yank(argv.get(2))
    }
    if cmd == "search" {
        q = ""
        remote = False
        i = 2
        while i < argv.len() {
            a = argv.get(i)
            if a == "--remote" or a == "--github" {
                remote = True
            } elif a == "--local" {
                remote = False
            } else {
                q = a
            }
            i = i + 1
        }
        return cmd_search(q, remote)
    }
    if cmd == "clean" {
        return cmd_clean(".")
    }
    if cmd == "registry" {
        print("registry: " + registry_dir())
        print("cache:    " + cache_dir())
        return 0
    }
    if cmd == "self" {
        return cmd_self(@argv)
    }

    print("error: unknown command `" + cmd + "`")
    print("hint: run `rack help`")
    return 1
}
