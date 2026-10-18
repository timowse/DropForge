# Test fixtures

`libarchive-rar4.rar` and `libarchive-rar5.rar` are uudecoded copies of
`test_read_format_rar.rar.uu` and `test_read_format_rar5_stored.rar.uu` from the libarchive
test suite (https://github.com/libarchive/libarchive, BSD-2-Clause, see `LIBARCHIVE-COPYING`).
No redistributable tool can create RAR files, so these two tiny samples are the only fixtures
not generated at test time. They are used only by tests and are not shipped in the app.
