@external(erlang, "tup_ffi", "read_file")
pub fn read(path: String) -> Result(BitArray, String)

pub fn reason_to_string(reason: String) -> String {
  case reason {
    "eacces" -> "permission was denied"
    "eperm" -> "the operation is not permitted"
    "eisdir" -> "the path is a directory"
    "enotdir" -> "a component of the path is not a directory"
    "eloop" -> "too many symbolic links were followed"
    "enametoolong" -> "the path is too long"
    "erofs" -> "the file system is read only"
    "ebusy" -> "the file is in use"
    "enomem" -> "the system ran out of memory"
    "enoent" -> "no such file or directory"
    "enxio" -> "the device does not exist"
    "badarg" -> "the path is not a usable file name"
    other_reason -> "the file system reported " <> other_reason
  }
}
