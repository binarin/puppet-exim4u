class exim4u::os_user($uid, $gid) {
  $home = "/home/exim4u"

  group { "exim4u":
    ensure => present,
    gid => $gid,
  } ->
  user { "exim4u":
    ensure => present,
    gid => $gid,
    home => $home,
    managehome => true,
    uid => $uid,
  }
}
