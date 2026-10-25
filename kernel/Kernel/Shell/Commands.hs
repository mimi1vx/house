{- | Pure shell command table: verb decoding shared by the loop and host tests.

'Cmd' has one constructor per dispatch target of the old @words@-case;
'parseCmd' moves that match here as a total function over 'words' output,
so @Loop@ only dispatches. Help text lives once in 'helpTable': 'cmdUsage'
projects one row per constructor and 'renderHelp' renders rows, so help
cannot drift from the dispatch table.

Verb decoding uses equality guards throughout: a @case@ over overloaded
numeric literals can collapse onto the first arm, while guards on distinct
verb words stay disjoint by construction.

This module is pure @base@ only: no FFI, no driver imports, so the host
test suite can import it without stubbing firmware symbols.
-}
module Kernel.Shell.Commands (
  Cmd (..),
  allCmds,
  cmdUsage,
  parseCmd,
  renderHelp,
) where

{- | One dispatch target per shell verb form; payloads bind exactly what
'words' delivered (static defaults stay in @Loop@, dynamic ones must:
'CmdConRead'\/'CmdBlkSync' resolve slots from the nameserver at runtime).
-}
data Cmd
  = CmdEmpty
  | CmdHelp
  | CmdEcho [String]
  | CmdClear
  | CmdUname [String]
  | CmdUptime
  | CmdShutdown [String]
  | CmdLambda
  | CmdPreempt
  | CmdWastemem String
  | CmdSmp
  | CmdSmpUp String
  | CmdSmpDown String
  | CmdCaps
  | CmdParfib String
  | CmdMvar String
  | CmdLs (Maybe String)
  | CmdCat String
  | CmdMkdir String
  | CmdRm String
  | CmdStat String
  | CmdWrite String String
  | CmdWriteUsage
  | CmdNsLs
  | CmdNsReg String
  | CmdNsRegUsage
  | CmdIpcPing String
  | CmdIpcPingUsage
  | CmdIpcGrant
  | CmdIpcEl0pp String
  | CmdIpcTimeout String
  | CmdIpcUsage
  | CmdLsdev
  | CmdDmesg
  | CmdDmesgClear
  | CmdVirtioScan
  | CmdVirtioInit String
  | CmdVirtioNotify String
  | CmdVirtioStatus
  | CmdVirtioAck String
  | CmdVirtioIrqtest String
  | CmdVirtioTeardown String
  | CmdVirtioUsage
  | CmdBlkInit String
  | CmdBlkStatus String
  | CmdBlkRead String String
  | CmdBlkWrite String String String
  | CmdBlkTeardown String
  | CmdBlkSync (Maybe String)
  | CmdBlkMount String
  | CmdBlkRoot String
  | CmdBlkUsage
  | CmdNetInit String
  | CmdNetStatus String
  | CmdNetTeardown String
  | CmdIfconfig
  | CmdPing String
  | CmdUdpEcho String String String
  | CmdArpLs
  | CmdNetDhcp
  | CmdDns String
  | CmdDnsUsage
  | CmdNetUsage
  | CmdConInit String
  | CmdConStatus String
  | CmdConWrite String String
  | CmdConRead (Maybe String)
  | CmdConTeardown String
  | CmdConMirror Bool
  | CmdConUsage
  | CmdFree
  | CmdMem
  | CmdDetect
  | CmdVm
  | CmdPalloc
  | CmdFdtest
  | CmdForktest
  | CmdLoaderRefs (Maybe String)
  | CmdThrowtest
  | CmdRun String [String]
  | CmdRunUsage
  | CmdSpawn String [String]
  | CmdSpawnUsage
  | CmdJobs
  | CmdWaitAll
  | CmdWaitOne String
  | CmdQuantumUsage
  | CmdQuantum String
  | CmdSvcMaskUsage
  | CmdSvcMask String String
  deriving (Eq, Show)

{- | One example value per constructor, in dispatch order; a test mapping
over this list touches every verb form and every help row.
-}
allCmds :: [Cmd]
allCmds =
  [ CmdEmpty
  , CmdHelp
  , CmdEcho ["hello"]
  , CmdClear
  , CmdUname ["-a"]
  , CmdUptime
  , CmdShutdown ["-h"]
  , CmdLambda
  , CmdPreempt
  , CmdWastemem "1024"
  , CmdSmp
  , CmdSmpUp "1"
  , CmdSmpDown "1"
  , CmdCaps
  , CmdParfib "10"
  , CmdMvar "100"
  , CmdLs Nothing
  , CmdLs (Just "/")
  , CmdCat "/init"
  , CmdMkdir "/tmp"
  , CmdRm "/tmp"
  , CmdStat "/"
  , CmdWrite "/f" "hi"
  , CmdWriteUsage
  , CmdNsLs
  , CmdNsReg "pl011"
  , CmdNsRegUsage
  , CmdIpcPing "pl011"
  , CmdIpcPingUsage
  , CmdIpcGrant
  , CmdIpcEl0pp "pl011"
  , CmdIpcTimeout "pl011"
  , CmdIpcUsage
  , CmdLsdev
  , CmdDmesg
  , CmdDmesgClear
  , CmdVirtioScan
  , CmdVirtioInit "0"
  , CmdVirtioNotify "0"
  , CmdVirtioStatus
  , CmdVirtioAck "0"
  , CmdVirtioIrqtest "0"
  , CmdVirtioTeardown "0"
  , CmdVirtioUsage
  , CmdBlkInit "0"
  , CmdBlkStatus "0"
  , CmdBlkRead "0" "0"
  , CmdBlkWrite "0" "0" "hi"
  , CmdBlkTeardown "0"
  , CmdBlkSync Nothing
  , CmdBlkSync (Just "0")
  , CmdBlkMount "0"
  , CmdBlkRoot "0"
  , CmdBlkUsage
  , CmdNetInit "0"
  , CmdNetStatus "0"
  , CmdNetTeardown "0"
  , CmdIfconfig
  , CmdPing "10.0.2.2"
  , CmdUdpEcho "10.0.2.2" "7" "hi"
  , CmdArpLs
  , CmdNetDhcp
  , CmdDns "example.com"
  , CmdDnsUsage
  , CmdNetUsage
  , CmdConInit "0"
  , CmdConStatus "0"
  , CmdConWrite "0" "hi"
  , CmdConRead Nothing
  , CmdConRead (Just "0")
  , CmdConTeardown "0"
  , CmdConMirror True
  , CmdConMirror False
  , CmdConUsage
  , CmdFree
  , CmdMem
  , CmdDetect
  , CmdVm
  , CmdPalloc
  , CmdFdtest
  , CmdForktest
  , CmdLoaderRefs Nothing
  , CmdLoaderRefs (Just "/bin/hello-dyn")
  , CmdThrowtest
  , CmdRun "/bin/hello" []
  , CmdRun "/bin/hello" ["a"]
  , CmdRunUsage
  , CmdSpawn "/bin/hello" []
  , CmdSpawnUsage
  , CmdJobs
  , CmdWaitAll
  , CmdWaitOne "1"
  , CmdQuantumUsage
  , CmdQuantum "10"
  , CmdSvcMaskUsage
  , CmdSvcMask "1" "0x14"
  ]

{- | Single source for help text: (line prefix, verb words, one-line help),
in display order, transcribed verbatim from the old @usage@ block.
-}
helpTable :: [(String, String, String)]
helpTable =
  [ ("Usage: ", "help | echo <word>... [> /path] | cat <path> | ls [path] | mkdir <path> | rm <path> | write <path> <text> | stat <path> | clear | uname [-asnrvmio] | uptime | shutdown [-h|-r]", "halt or reboot the machine")
  , ("       ", "lambda", "lambda demo")
  , ("       ", "preempt", "preemption demo")
  , ("       ", "wastemem <number>", "allocate memory")
  , ("       ", "free", "show H.Pages + buddy + ram")
  , ("       ", "mem", "show ram/stack/buddy+libc pool/ttbr")
  , ("       ", "detect", "show ram/stack/caps")
  , ("       ", "vm", "demand pager 100 pages + mmap/mprotect/munmap + isolate + asid+smp shootdown")
  , ("       ", "smp", "show SMP cores online | smp up <core> | smp down <core> -- hotplug to ceiling 32, caps mirror online")
  , ("       ", "caps", "show capabilities")
  , ("       ", "parfib <n>", "parallel fib")
  , ("       ", "mvar <n>", "MVar ping-pong test")
  , ("       ", "uname [-asnrvmio] [--help]", "print system information (default -s; -a all)")
  , ("       ", "ls [path]", "list directory")
  , ("       ", "cat <path>", "show file")
  , ("       ", "mkdir <path>", "create directory")
  , ("       ", "rm <path>", "remove file or empty dir")
  , ("       ", "write <path> <text>", "write file (truncate)")
  , ("       ", "stat <path>", "show file stat")
  , ("       ", "echo <word>... [> /path]", "echo or write via ramfs (volatile 2 MiB pool)")
  , ("       ", "ns ls", "list IPC names")
  , ("       ", "ns reg <name>", "register name (pl011 launches server)")
  , ("       ", "ipc ping <nsName>", "sync call to endpoint")
  , ("       ", "ipc grant", "alloc one page and send to pl011")
  , ("       ", "ipc timeout <nsName>", "bounded call that degrades to WouldBlock")
  , ("       ", "ipc el0pp <nsName>", "EL0 ping-pong: server RECV+REPLY + client CALL via the park ring")
  , ("       ", "lsdev", "list drivers | dmesg -- kernel log | virtio scan -- probe MMIO slots (0x0a000000+i*0x200)")
  , ("       ", "virtio scan|init <slot>|notify <slot>|status|ack <slot>|irqtest <slot>|teardown <slot>", "Virtio-MMIO transport (0x0a000000+i*0x200, split virtqueue, FEATURES_OK VIRTIO_F_VERSION_1|RING_F_EVENT_IDX, dc cvac/dsb, IRQ->Endpoint)")
  , ("       ", "blk init <slot>|status <slot>|read <slot> <lba>|write <slot> <lba> <text>|sync [slot]|mount <slot>|root <slot>|teardown <slot>", "Virtio-blk server (Endpoint, Grant, 4K blocks, capacity, queue_notify, IRQ->Endpoint, 64M house.img, Q2=B; mount restores RamFS, root appends a lower / layer for /lib reads and blocks teardown)")
  , ("       ", "net init <slot>|status <slot>|ifconfig|ping <ip>|udpecho <ip> <port> <text>|arp ls|dhcp|teardown <slot>", "Virtio-net server (Endpoint, Grant, rx0+tx1, 12B hdr, ARP/IPv4/UDP/DHCP, ping, dc ivac/dsb, IRQ->Endpoint, user net 10.0.2.0/24)")
  , ("       ", "dns <name>", "A-record lookup via 10.0.2.3 (UDP/53, no TCP; e.g. dns example.com)")
  , ("       ", "con init <slot>|status <slot>|write <slot> <text>|read [slot]|teardown <slot>|mirror on|off", "Virtio-console server (ID 3 console / multiport serial port0 + control q2/q3 DEVICE_READY/OPEN, Endpoint, Grant, rx0+tx1, dc ivac/dsb, IRQ->Endpoint; mirror duplicates UART to serial, default off)")
  , ("       ", "run </path> [args...]", "load static aarch64 ELF from ramfs 0x01000000 window, argv+env on EL0 stack, svc write/exit/brk/fd/ipc, EL0 eret (TTBR0/ASID/pager)")
  , ("       ", "spawn </path> [args...]", "run without waiting (prints pid) | jobs -- list live pids | wait [pid] -- reap (all when bare)")
  , ("       ", "quantum <ticks>", "preempt quantum in timer ticks (0..1000000, 0 means 1; default 10)")
  , ("       ", "svcmask <pid> <imm>", "revoke one syscall for a live pid (0x00..0x14)")
  , ("       ", "fdtest", "per-pid EL1 fd open/write/seek/read/close over ramfs (2 MiB cap; EL0 svc 0x04..0x07+0x0A ride the ring; cross-pid use fails EBADF)")
  , ("       ", "forktest", "EL1 forkProc COW share/diverge/leak check (stack page shared RO+cow, breakCow diverges, refs drain)")
  , ("       ", "loaderrefs [path]", "launch two dynamic images (default /bin/hello-dyn), verify finalized DSO page sharing, then drain refs")
  , ("       ", "throwtest", "throw from a handler; the dispatch catch must log it and answer the next command")
  ]

-- | Total row lookup into 'helpTable'; unknown rows render as blank.
tableRow :: Int -> (String, String)
tableRow n = case drop n helpTable of
  ((_, verbs, help) : _) -> (verbs, help)
  [] -> ("", "")

{- | Help row for a command: (verb words, one-line help). Families sharing
a usage line share its row; 'CmdEmpty' has no row and maps to blank.
-}
cmdUsage :: Cmd -> (String, String)
cmdUsage cmd = case cmd of
  CmdEmpty -> ("", "")
  CmdHelp -> tableRow 0
  CmdClear -> tableRow 0
  CmdUptime -> tableRow 0
  CmdShutdown _ -> tableRow 0
  CmdUname _ -> tableRow 12
  CmdEcho _ -> tableRow 19
  CmdLambda -> tableRow 1
  CmdPreempt -> tableRow 2
  CmdWastemem _ -> tableRow 3
  CmdSmp -> tableRow 8
  CmdSmpUp _ -> tableRow 8
  CmdSmpDown _ -> tableRow 8
  CmdCaps -> tableRow 9
  CmdParfib _ -> tableRow 10
  CmdMvar _ -> tableRow 11
  CmdLs _ -> tableRow 13
  CmdCat _ -> tableRow 14
  CmdMkdir _ -> tableRow 15
  CmdRm _ -> tableRow 16
  CmdWrite _ _ -> tableRow 17
  CmdWriteUsage -> tableRow 17
  CmdStat _ -> tableRow 18
  CmdNsLs -> tableRow 20
  CmdNsReg _ -> tableRow 21
  CmdNsRegUsage -> tableRow 21
  CmdIpcPing _ -> tableRow 22
  CmdIpcPingUsage -> tableRow 22
  CmdIpcUsage -> tableRow 22
  CmdIpcGrant -> tableRow 23
  CmdIpcTimeout _ -> tableRow 24
  CmdIpcEl0pp _ -> tableRow 25
  CmdLsdev -> tableRow 26
  CmdDmesg -> tableRow 26
  CmdDmesgClear -> tableRow 26
  CmdVirtioScan -> tableRow 27
  CmdVirtioInit _ -> tableRow 27
  CmdVirtioNotify _ -> tableRow 27
  CmdVirtioStatus -> tableRow 27
  CmdVirtioAck _ -> tableRow 27
  CmdVirtioIrqtest _ -> tableRow 27
  CmdVirtioTeardown _ -> tableRow 27
  CmdVirtioUsage -> tableRow 27
  CmdBlkInit _ -> tableRow 28
  CmdBlkStatus _ -> tableRow 28
  CmdBlkRead _ _ -> tableRow 28
  CmdBlkWrite {} -> tableRow 28
  CmdBlkTeardown _ -> tableRow 28
  CmdBlkSync _ -> tableRow 28
  CmdBlkMount _ -> tableRow 28
  CmdBlkRoot _ -> tableRow 28
  CmdBlkUsage -> tableRow 28
  CmdNetInit _ -> tableRow 29
  CmdNetStatus _ -> tableRow 29
  CmdNetTeardown _ -> tableRow 29
  CmdIfconfig -> tableRow 29
  CmdPing _ -> tableRow 29
  CmdUdpEcho {} -> tableRow 29
  CmdArpLs -> tableRow 29
  CmdNetDhcp -> tableRow 29
  CmdNetUsage -> tableRow 29
  CmdDns _ -> tableRow 30
  CmdDnsUsage -> tableRow 30
  CmdConInit _ -> tableRow 31
  CmdConStatus _ -> tableRow 31
  CmdConWrite _ _ -> tableRow 31
  CmdConRead _ -> tableRow 31
  CmdConTeardown _ -> tableRow 31
  CmdConMirror _ -> tableRow 31
  CmdConUsage -> tableRow 31
  CmdFree -> tableRow 4
  CmdMem -> tableRow 5
  CmdDetect -> tableRow 6
  CmdVm -> tableRow 7
  CmdPalloc -> tableRow 5
  CmdFdtest -> tableRow 36
  CmdForktest -> tableRow 37
  CmdLoaderRefs _ -> tableRow 38
  CmdThrowtest -> tableRow 39
  CmdRun _ _ -> tableRow 32
  CmdRunUsage -> tableRow 32
  CmdSpawn _ _ -> tableRow 33
  CmdSpawnUsage -> tableRow 33
  CmdJobs -> tableRow 33
  CmdWaitAll -> tableRow 33
  CmdWaitOne _ -> tableRow 33
  CmdQuantum _ -> tableRow 34
  CmdQuantumUsage -> tableRow 34
  CmdSvcMask _ _ -> tableRow 34
  CmdSvcMaskUsage -> tableRow 34

{- | Decode 'words' output into a command; 'Nothing' is an unknown verb
(the loop reports the raw line). Arity mismatches with a dedicated
@usage:@ one-liner decode to their @...Usage@ constructor; other
mismatches are unknown, exactly as the old inline case behaved.
-}
parseCmd :: [String] -> Maybe Cmd
parseCmd ws = case ws of
  [] -> Just CmdEmpty
  (verb : args)
    | verb == "help" -> Just CmdHelp
    | verb == "echo" -> Just (CmdEcho args)
    | verb == "clear", null args -> Just CmdClear
    | verb == "uname" -> Just (CmdUname args)
    | verb == "uptime", null args -> Just CmdUptime
    | verb == "shutdown" -> Just (CmdShutdown args)
    | verb == "lambda", null args -> Just CmdLambda
    | verb == "preempt", null args -> Just CmdPreempt
    | verb == "wastemem" -> case args of
        [n] -> Just (CmdWastemem n)
        _ -> Nothing
    | verb == "smp" -> case args of
        [] -> Just CmdSmp
        [a, n]
          | a == "up" -> Just (CmdSmpUp n)
          | a == "down" -> Just (CmdSmpDown n)
        _ -> Nothing
    | verb == "caps", null args -> Just CmdCaps
    | verb == "parfib" -> case args of
        [n] -> Just (CmdParfib n)
        _ -> Nothing
    | verb == "mvar" -> case args of
        [n] -> Just (CmdMvar n)
        _ -> Nothing
    | verb == "ls" -> case args of
        [] -> Just (CmdLs Nothing)
        [p] -> Just (CmdLs (Just p))
        _ -> Nothing
    | verb == "cat" -> case args of
        [p] -> Just (CmdCat p)
        _ -> Nothing
    | verb == "mkdir" -> case args of
        [p] -> Just (CmdMkdir p)
        _ -> Nothing
    | verb == "rm" -> case args of
        [p] -> Just (CmdRm p)
        _ -> Nothing
    | verb == "stat" -> case args of
        [p] -> Just (CmdStat p)
        _ -> Nothing
    | verb == "write" -> case args of
        [] -> Just CmdWriteUsage
        (p : rest) -> Just (CmdWrite p (unwords rest))
    | verb == "ns" -> case args of
        [a] | a == "ls" -> Just CmdNsLs
        [a, name] | a == "reg" -> Just (CmdNsReg name)
        [a] | a == "reg" -> Just CmdNsRegUsage
        _ -> Nothing
    | verb == "ipc" -> case args of
        [a, name] | a == "ping" -> Just (CmdIpcPing name)
        [a] | a == "ping" -> Just CmdIpcPingUsage
        [a] | a == "grant" -> Just CmdIpcGrant
        [a, name] | a == "el0pp" -> Just (CmdIpcEl0pp name)
        [a, name] | a == "timeout" -> Just (CmdIpcTimeout name)
        [] -> Just CmdIpcUsage
        _ -> Nothing
    | verb == "lsdev", null args -> Just CmdLsdev
    | verb == "dmesg" -> case args of
        [] -> Just CmdDmesg
        [a] | a == "clear" -> Just CmdDmesgClear
        _ -> Nothing
    | verb == "virtio" -> case args of
        [a] | a == "scan" -> Just CmdVirtioScan
        [a, s] | a == "init" -> Just (CmdVirtioInit s)
        [a, s] | a == "notify" -> Just (CmdVirtioNotify s)
        [a] | a == "status" -> Just CmdVirtioStatus
        [a, s] | a == "ack" -> Just (CmdVirtioAck s)
        [a, s] | a == "irqtest" -> Just (CmdVirtioIrqtest s)
        [a, s] | a == "teardown" -> Just (CmdVirtioTeardown s)
        [] -> Just CmdVirtioUsage
        _ -> Nothing
    | verb == "blk" -> case args of
        [a, s] | a == "init" -> Just (CmdBlkInit s)
        [a, s] | a == "status" -> Just (CmdBlkStatus s)
        [a, s, l] | a == "read" -> Just (CmdBlkRead s l)
        [a, s, l] | a == "write" -> Just (CmdBlkWrite s l "")
        [a, s, l, t] | a == "write" -> Just (CmdBlkWrite s l t)
        [a, s] | a == "teardown" -> Just (CmdBlkTeardown s)
        [a] | a == "sync" -> Just (CmdBlkSync Nothing)
        [a, s] | a == "sync" -> Just (CmdBlkSync (Just s))
        [a, s] | a == "mount" -> Just (CmdBlkMount s)
        [a, s] | a == "root" -> Just (CmdBlkRoot s)
        [] -> Just CmdBlkUsage
        _ -> Nothing
    | verb == "net" -> case args of
        [a, s] | a == "init" -> Just (CmdNetInit s)
        [a, s] | a == "status" -> Just (CmdNetStatus s)
        [a, s] | a == "teardown" -> Just (CmdNetTeardown s)
        [a] | a == "dhcp" -> Just CmdNetDhcp
        [] -> Just CmdNetUsage
        _ -> Nothing
    | verb == "ifconfig", null args -> Just CmdIfconfig
    | verb == "ping" -> case args of
        [ip] -> Just (CmdPing ip)
        _ -> Nothing
    | verb == "udpecho" -> case args of
        [ip, port, txt] -> Just (CmdUdpEcho ip port txt)
        [ip, port] -> Just (CmdUdpEcho ip port "")
        _ -> Nothing
    | verb == "arp" -> case args of
        [a] | a == "ls" -> Just CmdArpLs
        _ -> Nothing
    | verb == "dns" -> case args of
        [name] -> Just (CmdDns name)
        [] -> Just CmdDnsUsage
        _ -> Nothing
    | verb == "con" -> case args of
        [a, s] | a == "init" -> Just (CmdConInit s)
        [a, s] | a == "status" -> Just (CmdConStatus s)
        (a : s : rest) | a == "write" -> Just (CmdConWrite s (unwords rest))
        [a] | a == "read" -> Just (CmdConRead Nothing)
        [a, s] | a == "read" -> Just (CmdConRead (Just s))
        [a, s] | a == "teardown" -> Just (CmdConTeardown s)
        [a, b] | a == "mirror", b == "on" -> Just (CmdConMirror True)
        [a, b] | a == "mirror", b == "off" -> Just (CmdConMirror False)
        [] -> Just CmdConUsage
        _ -> Nothing
    | verb == "free", null args -> Just CmdFree
    | verb == "mem", null args -> Just CmdMem
    | verb == "detect", null args -> Just CmdDetect
    | verb == "vm", null args -> Just CmdVm
    | verb == "palloc", null args -> Just CmdPalloc
    | verb == "fdtest", null args -> Just CmdFdtest
    | verb == "forktest", null args -> Just CmdForktest
    | verb == "loaderrefs" -> case args of
        [] -> Just (CmdLoaderRefs Nothing)
        [p] -> Just (CmdLoaderRefs (Just p))
        _ -> Nothing
    | verb == "throwtest", null args -> Just CmdThrowtest
    | verb == "run" -> case args of
        [] -> Just CmdRunUsage
        (p : rest) -> Just (CmdRun p rest)
    | verb == "spawn" -> case args of
        [] -> Just CmdSpawnUsage
        (p : rest) -> Just (CmdSpawn p rest)
    | verb == "jobs", null args -> Just CmdJobs
    | verb == "wait" -> case args of
        [] -> Just CmdWaitAll
        [s] -> Just (CmdWaitOne s)
        _ -> Nothing
    | verb == "quantum" -> case args of
        [] -> Just CmdQuantumUsage
        [s] -> Just (CmdQuantum s)
        _ -> Nothing
    | verb == "svcmask" -> case args of
        [] -> Just CmdSvcMaskUsage
        [a, b] -> Just (CmdSvcMask a b)
        _ -> Nothing
    | otherwise -> Nothing

{- | Help text for a topic: @""@ or @"help"@ renders the full table;
otherwise every row mentioning the topic renders; unknown topics render
blank. The full render is byte-identical to the old @usage@ block.
-}
renderHelp :: String -> String
renderHelp topic
  | topic == "" || topic == "help" = fullUsage
  | otherwise = case matching of
      [] -> ""
      rows -> unlines rows
  where
    fullUsage = unlines [prefix ++ verbs ++ " -- " ++ help | (prefix, verbs, help) <- helpTable]
    matching = [prefix ++ verbs ++ " -- " ++ help | (prefix, verbs, help) <- helpTable, topic `elem` words verbs || topic `elem` words help]
