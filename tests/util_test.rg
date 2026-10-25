import util

# Standalone unit test for util's portable file/command helpers
# (run via util_test.sh; the real util.rg is staged next to this file).

def fail(msg: str) -> int {
    print("FAIL: " + msg)
    return 1
}

def main() -> int {
    base = temp_path("util-test")
    if not mkdirs(base) {
        return fail("mkdirs")
    }
    if not is_dir_path(base) {
        return fail("is_dir_path(existing)")
    }
    if is_dir_path(base + "/missing") {
        return fail("is_dir_path(missing)")
    }

    xs = output_lines(" a \n\n b\r\nc \t\n")
    if xs.len() != 3 {
        return fail("output_lines count: " + to_string(xs.len()))
    }
    if xs.get(0) != "a" or xs.get(1) != "b" or xs.get(2) != "c" {
        return fail("output_lines content")
    }

    # copy/remove only *.rg, never other files
    src = base + "/src"
    dst = base + "/dst"
    mkdirs(src)
    mkdirs(dst)
    write_file(src + "/a.rg", "a")
    write_file(src + "/b.rg", "b")
    write_file(src + "/note.txt", "n")
    if not copy_rg_files(src, dst) {
        return fail("copy_rg_files")
    }
    if list_dir(dst).len() != 2 {
        return fail("copy_rg_files staged " + to_string(list_dir(dst).len()) + " files")
    }
    remove_rg_files(dst)
    if list_dir(dst).len() != 0 {
        return fail("remove_rg_files left files")
    }
    empty = base + "/empty"
    mkdirs(empty)
    if copy_rg_files(empty, dst) {
        return fail("copy_rg_files(empty) should fail")
    }

    mv_src = base + "/old"
    mv_dst = base + "/new"
    mkdirs(mv_src)
    write_file(mv_src + "/x.rg", "x")
    if not move_path(mv_src, mv_dst) {
        return fail("move_path")
    }
    if is_dir_path(mv_src) {
        return fail("move_path left source")
    }
    if not is_dir_path(mv_dst) {
        return fail("move_path destination missing")
    }
    if list_dir(mv_dst).len() != 1 {
        return fail("move_path lost contents")
    }
    if not remove_dir_all(mv_dst) {
        return fail("remove_dir_all")
    }
    if is_dir_path(mv_dst) {
        return fail("remove_dir_all left directory")
    }
    if not remove_dir_all(base + "/missing") {
        return fail("remove_dir_all(missing) should succeed")
    }

    write_file(base + "/hash.txt", "abc")
    if file_sha256(base + "/hash.txt") !=
       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" {
        return fail("file_sha256 content")
    }
    if file_sha256(base + "/nope.txt") != "" {
        return fail("file_sha256(missing)")
    }

    if path_base_name("a/b/c.rg") != "c.rg" {
        return fail("path_base_name(/)")
    }
    if path_base_name("a\\b\\c.rg") != "c.rg" {
        return fail("path_base_name(\\)")
    }
    if path_base_name("c.rg") != "c.rg" {
        return fail("path_base_name(bare)")
    }

    remove_dir_all(base)
    print("util-ok")
    return 0
}
