//! Celori network service, the socket half (E10 part 2): UDP endpoints under the host's policy, peers by number, bounded and non-blocking. Plain std, no wasmtime: net.rs binds it to the
//! guest (celori:net), and the cross-OS check (atyr647/ci, celori-net) builds and tests this file alone on Windows, macOS and Linux.
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs, UdpSocket};

pub const MAX_DATAGRAM: usize = 1200;
pub const MAX_PER_RECV: usize = 256;
pub const MAX_ENDPOINTS: usize = 64;
pub const MAX_PEERS: usize = 65536;

#[derive(Default)]
pub struct NetPolicy { pub listen: Vec<SocketAddr>, pub connect: Vec<SocketAddr> }

impl NetPolicy {
    /// Parses one flag value ("127.0.0.1:7777"); names are resolved once, here, never by the guest.
    pub fn parse_addr(s: &str) -> Result<SocketAddr, String> {
        if s.len() > 256 { return Err("address too long".into()); }
        s.to_socket_addrs().map_err(|e| format!("{s:?}: {e}"))?.next().ok_or_else(|| format!("{s:?}: no address"))
    }
    pub fn enabled(&self) -> bool { !self.listen.is_empty() || !self.connect.is_empty() }
}

#[derive(Default, Debug, Clone)]
pub struct NetReport { pub backend: String, pub endpoints: u64, pub sent: u64, pub sent_bytes: u64, pub received: u64, pub received_bytes: u64, pub dropped_large: u64, pub dropped_peers: u64, pub refused: u64, pub icmp_errors: u64 }

pub struct NetState {
    policy: NetPolicy,
    endpoints: HashMap<u32, UdpSocket>,
    next_endpoint: u32,
    peers: Vec<SocketAddr>,                 // peer number n is peers[n - 1]
    peer_of: HashMap<SocketAddr, u64>,
    report: NetReport,
}

impl NetState {
    pub fn new(policy: NetPolicy) -> Self {
        let backend = if policy.enabled() { "udp" } else { "none" };
        Self { policy, endpoints: HashMap::new(), next_endpoint: 1, peers: Vec::new(), peer_of: HashMap::new(), report: NetReport { backend: backend.into(), ..Default::default() } }
    }
    pub fn report(&self) -> NetReport { self.report.clone() }
    fn none(&self) -> bool { !self.policy.enabled() }
    fn refuse<T>(&mut self, why: String) -> Result<T, String> { self.report.refused += 1; Err(why) }
    pub fn backend(&self) -> &str { &self.report.backend }

    fn peer_number(&mut self, addr: SocketAddr) -> Option<u64> {
        if let Some(&n) = self.peer_of.get(&addr) { return Some(n); }
        if self.peers.len() >= MAX_PEERS { return None; }
        self.peers.push(addr);
        let n = self.peers.len() as u64;
        self.peer_of.insert(addr, n);
        Some(n)
    }

    pub fn bind(&mut self, address: &str) -> Result<u32, String> {
        if self.none() { return self.refuse("this host has no network (start it with --net-listen or --net-connect)".into()); }
        if self.endpoints.len() >= MAX_ENDPOINTS { return self.refuse(format!("at most {MAX_ENDPOINTS} endpoints")); }
        let want = NetPolicy::parse_addr(address)?;
        // allowed: an address given with --net-listen, or (for a client) any port on the unspecified address of a family it may connect with
        let client_ok = want.port() == 0 && want.ip().is_unspecified() && self.policy.connect.iter().any(|c| c.is_ipv4() == want.is_ipv4());
        if !self.policy.listen.contains(&want) && !client_ok { return self.refuse(format!("listening on {want} is not allowed (--net-listen)")); }
        let sock = UdpSocket::bind(want).map_err(|e| format!("bind {want}: {e}"))?;
        sock.set_nonblocking(true).map_err(|e| e.to_string())?;
        let id = self.next_endpoint;
        self.next_endpoint += 1;
        self.endpoints.insert(id, sock);
        self.report.endpoints += 1;
        Ok(id)
    }

    pub fn local_address(&self, endpoint: u32) -> Result<String, String> {
        let s = self.endpoints.get(&endpoint).ok_or("no such endpoint")?;
        s.local_addr().map(|a| a.to_string()).map_err(|e| e.to_string())
    }

    pub fn peer(&mut self, address: &str) -> Result<u64, String> {
        if self.none() { return self.refuse("this host has no network".into()); }
        let a = NetPolicy::parse_addr(address)?;
        if !self.policy.connect.contains(&a) { return self.refuse(format!("reaching {a} is not allowed (--net-connect)")); }
        self.peer_number(a).ok_or_else(|| "too many peers".into())
    }

    pub fn send(&mut self, endpoint: u32, to: u64, data: &[u8]) -> Result<(), String> {
        if data.len() > MAX_DATAGRAM { return self.refuse(format!("a datagram of {} bytes (at most {MAX_DATAGRAM})", data.len())); }
        let addr = *self.peers.get((to as usize).wrapping_sub(1)).ok_or("no such peer")?;
        let sock = self.endpoints.get(&endpoint).ok_or("no such endpoint")?;
        match sock.send_to(data, addr) {
            Ok(_) => { self.report.sent += 1; self.report.sent_bytes += data.len() as u64; Ok(()) }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(()),        // the socket's buffer is full: as good as lost on the way
            Err(e) => Err(format!("send to {addr}: {e}")),
        }
    }

    pub fn recv(&mut self, endpoint: u32) -> Vec<(u64, Vec<u8>)> {
        let mut out = Vec::new();
        let Some(sock) = self.endpoints.get(&endpoint) else { return out; };
        let sock = sock.try_clone();
        let Ok(sock) = sock else { return out; };
        let mut buf = [0u8; MAX_DATAGRAM + 1];
        while out.len() < MAX_PER_RECV {
            match sock.recv_from(&mut buf) {
                Ok((n, from)) => {
                    if n > MAX_DATAGRAM { self.report.dropped_large += 1; continue; }
                    match self.peer_number(from) {
                        Some(p) => { self.report.received += 1; self.report.received_bytes += n as u64; out.push((p, buf[..n].to_vec())); }
                        None => self.report.dropped_peers += 1,
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                // Windows reports an ICMP "port unreachable" for an earlier send as an error of a later recv_from (WSAECONNRESET), and Linux can report ECONNREFUSED: neither means there
                // is nothing more to read; skip it and read on (a bounded number of times)
                Err(e) if matches!(e.kind(), std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionRefused) => { self.report.icmp_errors += 1; if self.report.icmp_errors % 1024 == 0 { break; } continue; }
                Err(_) => break,
            }
        }
        out
    }

    pub fn close(&mut self, endpoint: u32) { self.endpoints.remove(&endpoint); }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn policy(listen: &[&str], connect: &[&str]) -> NetPolicy {
        NetPolicy { listen: listen.iter().map(|s| NetPolicy::parse_addr(s).unwrap()).collect(), connect: connect.iter().map(|s| NetPolicy::parse_addr(s).unwrap()).collect() }
    }
    #[test]
    fn none_refuses_everything() {
        let mut n = NetState::new(NetPolicy::default());
        assert_eq!(n.report().backend, "none");
        assert!(n.bind("127.0.0.1:0").is_err());
        assert!(n.peer("127.0.0.1:7777").is_err());
    }
    #[test]
    fn policy_limits_listen_and_connect() {
        let mut n = NetState::new(policy(&["127.0.0.1:0"], &["127.0.0.1:9"]));
        assert!(n.bind("127.0.0.1:0").is_ok());
        assert!(n.bind("127.0.0.2:0").is_err(), "an address not allowed to listen on");
        assert!(n.peer("127.0.0.1:9").is_ok());
        assert!(n.peer("127.0.0.1:10").is_err(), "a peer not allowed");
        assert_eq!(n.peer("127.0.0.1:9").unwrap(), n.peer("127.0.0.1:9").unwrap(), "the same address, the same number");
    }
    #[test]
    fn loopback_exchange_and_limits() {
        let mut server = NetState::new(policy(&["127.0.0.1:0"], &[]));
        let se = server.bind("127.0.0.1:0").unwrap();
        let saddr = server.local_address(se).unwrap();
        let mut client = NetState::new(policy(&[], &[&saddr]));
        let ce = client.bind("0.0.0.0:0").unwrap();
        let sp = client.peer(&saddr).unwrap();
        client.send(ce, sp, b"hello").unwrap();
        assert!(client.send(ce, sp, &vec![0u8; MAX_DATAGRAM + 1]).is_err(), "a datagram over the limit is refused");
        let mut got = Vec::new();
        for _ in 0..200 { got = server.recv(se); if !got.is_empty() { break; } std::thread::sleep(std::time::Duration::from_millis(5)); }
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].1, b"hello");
        let cp = got[0].0;
        server.send(se, cp, b"back").unwrap();
        let mut back = Vec::new();
        for _ in 0..200 { back = client.recv(ce); if !back.is_empty() { break; } std::thread::sleep(std::time::Duration::from_millis(5)); }
        assert_eq!(back.len(), 1);
        assert_eq!(back[0], (sp, b"back".to_vec()), "the answer comes from the peer the client named");
        assert!(server.send(se, 999, b"x").is_err(), "an unknown peer number");
    }
}
