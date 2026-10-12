# Private, documentation, loopback and catch-all ranges never match, even
# when the feed lists them.
locals {
  private   = ["10.0.0.1", "10.0.0.0/8", "172.16.5.5", "192.168.1.1"]
  docs      = ["192.0.2.1", "198.51.100.0/24", "203.0.113.5"]
  loopback  = ["127.0.0.1", "::1"]
  link      = "169.254.169.254"
  catch_all = "0.0.0.0/0"
  text      = "c2.example.com"
}
