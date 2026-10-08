import Testing
@testable import FarolCore

@Test func readsTheHostFromShellTitles() {
    let ubuntu = RemoteTitle("root@srv1555787: ~/apps", localHost: "mac.local")
    #expect(ubuntu?.user == "root")
    #expect(ubuntu?.host == "srv1555787")
    #expect(ubuntu?.path == "~/apps")
    #expect(RemoteTitle("deploy@web1:/var/www", localHost: "mac.local")?.path == "/var/www")
    #expect(RemoteTitle("deploy@web1.example.com:~", localHost: "mac.local")?.host == "web1.example.com")
}

@Test func aLocalShellIsNotRemote() {
    #expect(RemoteTitle("lucas@mac: ~/dev", localHost: "mac.local") == nil)
    #expect(RemoteTitle("lucas@Mac.local:~/dev", localHost: "mac") == nil)
}

@Test func programTitlesAreNotRemote() {
    #expect(RemoteTitle("ssh root@srv1555787", localHost: "mac") == nil)
    #expect(RemoteTitle("vim notes: me@web1", localHost: "mac") == nil)
    #expect(RemoteTitle("~/dev/farol", localHost: "mac") == nil)
    #expect(RemoteTitle("", localHost: "mac") == nil)
}
