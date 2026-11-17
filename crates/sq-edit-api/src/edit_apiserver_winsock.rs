// Swift: EditAPIServer+Winsock.swift
//! Not a separate port: the Swift Windows server (blocking winsock sockets, one thread per connection) is replaced by
//! the `std::net` server in `edit_apiserver_network`, which behaves the same on both systems (loopback only, 8
//! connections, 15 s deadline, one request per connection).
