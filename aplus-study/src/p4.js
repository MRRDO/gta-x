
/* ---------- FLASHCARDS (Leitner spaced repetition) ---------- */
const CARDS = [
{i:"c01",d:"c1d2",t:"FTP",b:"File Transfer Protocol — TCP 20 (data) and 21 (control)",x:"Plaintext. Use SFTP (22) or FTPS instead when credentials matter."},
{i:"c02",d:"c1d2",t:"SSH",b:"Secure Shell — TCP 22",x:"Encrypted remote CLI. Also carries SFTP and SCP on the same port."},
{i:"c03",d:"c1d2",t:"Telnet",b:"Remote CLI in clear text — TCP 23",x:"Never use on a production network. SSH exists."},
{i:"c04",d:"c1d2",t:"SMTP",b:"Simple Mail Transfer Protocol — TCP 25 (587 for authenticated submission with TLS)",x:"Outbound mail only. Receiving is IMAP or POP3."},
{i:"c05",d:"c1d2",t:"DNS",b:"Domain Name System — UDP/TCP 53",x:"Resolves names to IPs. Broken DNS = IP works, hostname does not."},
{i:"c06",d:"c1d2",t:"DHCP",b:"Dynamic Host Configuration Protocol — UDP 67 (server) and 68 (client)",x:"DORA: Discover, Offer, Request, Acknowledge."},
{i:"c07",d:"c1d2",t:"TFTP",b:"Trivial FTP — UDP 69",x:"No authentication. Used for network device firmware and PXE boot."},
{i:"c08",d:"c1d2",t:"HTTP / HTTPS",b:"TCP 80 / TCP 443",x:"443 also carries most VPN and API traffic because it is almost never blocked."},
{i:"c09",d:"c1d2",t:"POP3 / IMAP",b:"POP3 TCP 110 (995 secure); IMAP TCP 143 (993 secure)",x:"IMAP syncs across devices; POP3 traditionally downloads and deletes."},
{i:"c10",d:"c1d2",t:"NetBIOS / NetBT",b:"TCP/UDP 137, 138, 139",x:"Legacy Windows name service. Modern SMB uses 445 directly."},
{i:"c11",d:"c1d2",t:"SNMP",b:"Simple Network Management Protocol — UDP 161 (queries), 162 (traps)",x:"Use v3 — v1 and v2c send community strings in clear text."},
{i:"c12",d:"c1d2",t:"LDAP / LDAPS",b:"TCP 389 / TCP 636",x:"Directory lookups against Active Directory and other directory services."},
{i:"c13",d:"c1d2",t:"SMB / CIFS",b:"TCP 445",x:"Windows file and printer sharing. Block it at the internet edge."},
{i:"c14",d:"c1d2",t:"RDP",b:"Remote Desktop Protocol — TCP 3389",x:"Put it behind a VPN. Exposed RDP is a top ransomware entry point."},
{i:"c15",d:"c1d3",t:"RAID 0",b:"Striping. Speed and full capacity, zero redundancy.",x:"One drive dies, the whole array dies."},
{i:"c16",d:"c1d3",t:"RAID 1",b:"Mirroring. Identical copy on two drives; you get half the raw capacity.",x:"Survives one drive failure. Fast reads, no write speed gain."},
{i:"c17",d:"c1d3",t:"RAID 5",b:"Striping with distributed parity, 3+ drives. Survives one failure.",x:"Usable capacity = (n-1) drives. Rebuilds are slow and stressful on big disks."},
{i:"c18",d:"c1d3",t:"RAID 6",b:"Striping with double distributed parity, 4+ drives. Survives two failures.",x:"Usable capacity = (n-2). The answer for large-capacity arrays."},
{i:"c19",d:"c1d3",t:"RAID 10",b:"Mirrored sets that are then striped. 4+ drives, half capacity.",x:"Best performance plus redundancy. What you put a database on."},
{i:"c20",d:"c1d3",t:"SODIMM",b:"Small Outline DIMM — the short memory module used in laptops and small-form-factor PCs",x:"DDR5 SODIMM is 262 pins; the desktop DDR5 DIMM is 288."},
{i:"c21",d:"c1d3",t:"M.2 2280",b:"An M.2 module 22 mm wide by 80 mm long",x:"Sizing is always width then length. 2230 is the short one, 22110 the long one."},
{i:"c22",d:"c1d3",t:"NVMe",b:"Non-Volatile Memory Express — a storage protocol running over PCIe lanes",x:"Bypasses the ~600 MB/s SATA III ceiling; PCIe 4.0 x4 drives exceed 7,000 MB/s."},
{i:"c23",d:"c1d3",t:"LGA vs PGA",b:"LGA = pins on the motherboard socket. PGA = pins on the CPU.",x:"Bent LGA socket pins usually mean a new motherboard."},
{i:"c24",d:"c1d3",t:"Laser printing steps",b:"Processing, Charging, Exposing, Developing, Transferring, Fusing, Cleaning",x:"Mnemonic: Please Come Every Day To Fix Computers."},
{i:"c25",d:"c1d3",t:"80 PLUS",b:"A PSU efficiency certification (Bronze through Titanium)",x:"Rates efficiency, not wattage. Higher tier = less waste heat."},
{i:"c26",d:"c1d3",t:"TDP",b:"Thermal Design Power — the heat a cooler must dissipate, in watts",x:"Match your cooler's rating to the CPU TDP or you throttle under load."},
{i:"c27",d:"c1d1",t:"NFC",b:"Near Field Communication — roughly 4 cm range",x:"Tap to pay. The tiny range IS part of the security model."},
{i:"c28",d:"c1d1",t:"MDM",b:"Mobile Device Management — enrollment-based policy, remote wipe, app control",x:"On BYOD it usually wipes only the managed work container."},
{i:"c29",d:"c1d4",t:"IaaS / PaaS / SaaS",b:"Infrastructure / Platform / Software as a Service",x:"EC2 is IaaS, Heroku is PaaS, Gmail is SaaS."},
{i:"c30",d:"c1d4",t:"Type 1 hypervisor",b:"Bare-metal — runs directly on hardware with no host OS",x:"ESXi, Hyper-V, Proxmox. Type 2 (VirtualBox) runs as an app on a host OS."},
{i:"c31",d:"c1d4",t:"VDI",b:"Virtual Desktop Infrastructure — desktops hosted centrally, accessed from thin clients",x:"No data on the endpoint, so a dead thin client is a five-minute swap."},
{i:"c32",d:"c1d5",t:"Troubleshooting methodology",b:"Identify > Theory > Test theory > Plan of action > Implement > Verify > Document",x:"Documenting findings, actions, and outcomes is ALWAYS the last step."},
{i:"c33",d:"c1d5",t:"APIPA",b:"Automatic Private IP Addressing — 169.254.x.x with mask 255.255.0.0",x:"Means the client never got a DHCP lease."},
{i:"c34",d:"c1d5",t:"Loopback plug",b:"Feeds a port's transmit pins back to its receive pins to test the port itself",x:"Passes loopback but link is down = the cable or switch is the problem, not the NIC."},
{i:"c35",d:"c1d5",t:"Tone generator and probe",b:"Traces WHERE an unlabeled cable goes",x:"A cable tester checks whether a cable is wired correctly. Different job."},
{i:"c36",d:"c2d1",t:"sfc /scannow",b:"System File Checker — verifies and repairs protected Windows system files",x:"If it fails, run DISM /Online /Cleanup-Image /RestoreHealth then retry."},
{i:"c37",d:"c2d1",t:"chkdsk /f vs /r",b:"/f fixes file system errors; /r also scans for bad sectors and recovers readable data",x:"/r takes much longer. On the system drive it schedules for next reboot."},
{i:"c38",d:"c2d1",t:"gpupdate vs gpresult",b:"gpupdate /force APPLIES group policy; gpresult /r REPORTS what is applied",x:"Standard flow: gpupdate /force, then gpresult /r to confirm."},
{i:"c39",d:"c2d1",t:"MBR vs GPT",b:"MBR: 2 TB limit, 4 primary partitions. GPT: huge disks, up to 128 partitions, pairs with UEFI.",x:"Windows 11 + Secure Boot requires GPT."},
{i:"c40",d:"c2d1",t:"FAT32 / exFAT / NTFS",b:"FAT32: 4 GB file cap, universal. exFAT: cross-platform, no practical cap. NTFS: Windows, permissions and journaling.",x:"A 6 GB file that will not copy to a stick showing 50 GB free = FAT32."},
{i:"c41",d:"c2d1",t:"net use",b:"Maps, lists, or disconnects network drives from the Windows command line",x:"net use Z: \\\\server\\share /persistent:yes"},
{i:"c42",d:"c2d1",t:"chmod 755",b:"Owner: read+write+execute (7). Group and others: read+execute (5).",x:"Read=4, Write=2, Execute=1. Add them up per position."},
{i:"c43",d:"c2d2",t:"MFA factors",b:"Something you know, something you have, something you are (plus somewhere you are)",x:"Password + PIN is NOT MFA — both are things you know."},
{i:"c44",d:"c2d2",t:"Principle of least privilege",b:"Grant only the access required to do the job, nothing more",x:"Limits the blast radius when an account is compromised."},
{i:"c45",d:"c2d2",t:"TPM",b:"Trusted Platform Module — tamper-resistant hardware that stores keys and measures boot integrity",x:"Lets BitLocker unlock silently on a healthy boot and demand recovery after tampering."},
{i:"c46",d:"c2d2",t:"Malware removal steps",b:"Investigate/verify > Quarantine > Disable System Restore > Remediate > Schedule scans and updates > Re-enable System Restore > Educate the user",x:"Quarantine comes before ANY cleanup. Education is always last."},
{i:"c47",d:"c2d2",t:"Evil twin",b:"A rogue AP broadcasting a legitimate SSID to intercept client traffic",x:"WPA2/3-Enterprise with certificate validation defeats it."},
{i:"c48",d:"c2d2",t:"Degaussing",b:"Destroying magnetic media by scrambling its magnetic domains",x:"Does nothing to an SSD. SSDs need crypto-erase or shredding."},
{i:"c49",d:"c2d4",t:"3-2-1 backup rule",b:"3 copies, on 2 different media types, with 1 stored offsite",x:"Two drives in the same building is not 3-2-1 — one fire takes both."},
{i:"c50",d:"c2d4",t:"RTO vs RPO",b:"RTO = how fast you must be back up. RPO = how much data you can afford to lose.",x:"RPO of 1 hour means backups run at least hourly."},
{i:"c51",d:"c2d4",t:"Incremental vs differential",b:"Incremental: changes since the last backup of any type. Differential: changes since the last FULL.",x:"Incremental backs up fast, restores slow. Differential is the reverse."},
{i:"c52",d:"c2d4",t:"Class C extinguisher",b:"For energized electrical fires",x:"A = ordinary combustibles, B = flammable liquids, C = electrical, D = combustible metals."},
{i:"c53",d:"c2d4",t:"SDS / MSDS",b:"Safety Data Sheet — hazards, PPE, first aid, spill response, and disposal for a chemical",x:"Toner spills: ESD-safe vacuum and COLD water only. Hot water fuses it permanently."},
{i:"c54",d:"c2d4",t:"PII / PHI / PCI",b:"Personally identifiable info / protected health info (HIPAA) / payment card data (PCI DSS)",x:"Classification determines the legal notification duty after a breach."},
{i:"c55",d:"c2d2",t:"WPA3",b:"Current Wi-Fi security standard; Personal mode uses SAE instead of a PSK handshake",x:"SAE defeats the offline dictionary attacks that hurt WPA2."},
{i:"c56",d:"c1d2",t:"T568B pin order",b:"W/Orange, Orange, W/Green, Blue, W/Blue, Green, W/Brown, Brown",x:"T568A swaps the orange and green pairs. Same standard both ends = straight-through."},
{i:"c57",d:"c1d3",t:"ECC memory",b:"Error-Correcting Code memory — detects and corrects single-bit errors",x:"Servers and workstations. Most consumer boards will not accept it."},
{i:"c58",d:"c1d5",t:"SMART",b:"Self-Monitoring, Analysis and Reporting Technology — drive self-diagnostics",x:"Rising reallocated sector count = back up now and replace the drive."},
{i:"c59",d:"c2d1",t:"Safe Mode",b:"Boots Windows with a minimal driver and service set",x:"Problem gone in Safe Mode = a third-party driver, startup app, or malware is the cause."},
{i:"c60",d:"c2d3",t:"Kernel-Power Event ID 41",b:"Windows logs this when the system lost power or hard-locked without a clean shutdown",x:"Points at PSU, power delivery, or heat — not software."}
];

/* ---------- SPEED ROUND (ports and acronyms, auto-generated distractors) ---------- */
const SPEED = [
{q:"FTP",a:"20/21"},{q:"SSH / SFTP",a:"22"},{q:"Telnet",a:"23"},{q:"SMTP",a:"25"},
{q:"DNS",a:"53"},{q:"DHCP",a:"67/68"},{q:"TFTP",a:"69"},{q:"HTTP",a:"80"},
{q:"POP3",a:"110"},{q:"NetBIOS",a:"137/139"},{q:"IMAP",a:"143"},{q:"SNMP",a:"161/162"},
{q:"LDAP",a:"389"},{q:"HTTPS",a:"443"},{q:"SMB",a:"445"},{q:"SMTP over TLS",a:"587"},
{q:"LDAPS",a:"636"},{q:"IMAP over SSL",a:"993"},{q:"POP3 over SSL",a:"995"},{q:"RDP",a:"3389"},
{q:"PII",a:"Personally Identifiable Information"},{q:"UEFI",a:"Unified Extensible Firmware Interface"},
{q:"TPM",a:"Trusted Platform Module"},{q:"NVMe",a:"Non-Volatile Memory Express"},
{q:"SODIMM",a:"Small Outline DIMM"},{q:"ESD",a:"Electrostatic Discharge"},
{q:"MDM",a:"Mobile Device Management"},{q:"VDI",a:"Virtual Desktop Infrastructure"},
{q:"APIPA",a:"Automatic Private IP Addressing"},{q:"NAT",a:"Network Address Translation"},
{q:"PoE",a:"Power over Ethernet"},{q:"SSID",a:"Service Set Identifier"},
{q:"WPA3",a:"Wi-Fi Protected Access 3"},{q:"ACL",a:"Access Control List"},
{q:"RBAC",a:"Role-Based Access Control"},{q:"SDS",a:"Safety Data Sheet"},
{q:"RTO",a:"Recovery Time Objective"},{q:"RPO",a:"Recovery Point Objective"},
{q:"AUP",a:"Acceptable Use Policy"},{q:"EDR",a:"Endpoint Detection and Response"},
{q:"SMART",a:"Self-Monitoring, Analysis and Reporting Technology"},
{q:"MST",a:"Multi-Stream Transport"},{q:"ECC",a:"Error-Correcting Code"},
{q:"TDP",a:"Thermal Design Power"},{q:"IdP",a:"Identity Provider"},
{q:"SSO",a:"Single Sign-On"},{q:"MFA",a:"Multifactor Authentication"},
{q:"GPT",a:"GUID Partition Table"},{q:"MBR",a:"Master Boot Record"},
{q:"PXE",a:"Preboot Execution Environment"}
];

/* ---------- PBQ SIMS (drag/tap to place) ---------- */
const PBQS = [
{
 i:"pb1", d:"c1d5", title:"Troubleshooting methodology",
 kind:"order",
 prompt:"Place the six steps of the CompTIA troubleshooting methodology in the correct order.",
 items:["Identify the problem","Establish a theory of probable cause","Test the theory to determine the cause","Establish a plan of action and implement the solution","Verify full system functionality and implement preventive measures","Document findings, actions, and outcomes"],
 why:"Order is heavily tested. Note that identifying the problem includes backing up and asking about recent changes, and documentation is always last."
},
{
 i:"pb2", d:"c1d3", title:"T568B termination",
 kind:"order",
 prompt:"Place the T568B wire colors in order from pin 1 to pin 8.",
 items:["White/Orange","Orange","White/Green","Blue","White/Blue","Green","White/Brown","Brown"],
 why:"T568A is identical with the orange and green pairs swapped. Same standard on both ends makes a straight-through cable."
},
{
 i:"pb3", d:"c1d3", title:"Laser imaging process",
 kind:"order",
 prompt:"Place the seven steps of the laser printing process in order.",
 items:["Processing","Charging","Exposing","Developing","Transferring","Fusing","Cleaning"],
 why:"Please Come Every Day To Fix Computers. Knowing the order lets you map a symptom to a step — smearing toner means fusing failed."
},
{
 i:"pb4", d:"c1d2", title:"Port assignment",
 kind:"match",
 prompt:"Match each protocol to its port number.",
 slots:[["HTTPS","443"],["RDP","3389"],["SSH","22"],["DNS","53"],["SMB","445"],["IMAP over SSL","993"]],
 why:"These six show up constantly. HTTPS 443 and RDP 3389 in particular appear on nearly every practice exam."
},
{
 i:"pb5", d:"c1d3", title:"RAID selection",
 kind:"match",
 prompt:"Match each RAID level to its description.",
 slots:[["RAID 0","Striping, no redundancy"],["RAID 1","Mirroring, half capacity"],["RAID 5","Striping with single parity"],["RAID 6","Striping with double parity"],["RAID 10","Mirrored sets, then striped"]],
 why:"RAID 5 survives one drive loss, RAID 6 survives two, RAID 0 survives none. RAID 10 is what you put a database on."
},
{
 i:"pb6", d:"c2d1", title:"Windows tools",
 kind:"match",
 prompt:"Match each task to the correct Windows utility.",
 slots:[["Repair corrupted system files","sfc /scannow"],["View IP, gateway, DNS, and MAC","ipconfig /all"],["Create or delete partitions","diskpart"],["Force a Group Policy refresh","gpupdate /force"],["Review system and application logs","Event Viewer"],["Map a network drive","net use"]],
 why:"Command-line utilities are guaranteed exam content. Know what each one does AND which switch you need."
},
{
 i:"pb7", d:"c2d2", title:"Malware remediation",
 kind:"order",
 prompt:"Place CompTIA's malware removal steps in order.",
 items:["Investigate and verify malware symptoms","Quarantine the infected system","Disable System Restore in Windows","Remediate: update anti-malware and scan","Schedule scans and run updates","Re-enable System Restore and create a restore point","Educate the end user"],
 why:"Quarantine comes before any cleanup, System Restore gets disabled so infected restore points are purged, and education is always last."
},
{
 i:"pb8", d:"c1d5", title:"Tool selection",
 kind:"match",
 prompt:"Match each troubleshooting scenario to the right tool.",
 slots:[["Find which patch panel port a jack lands on","Tone generator and probe"],["Verify a cable is wired pin-for-pin","Cable tester"],["Test whether a NIC can send and receive","Loopback plug"],["Check a PSU rail voltage","Multimeter"],["Trace the path to a remote host","tracert / traceroute"]],
 why:"The exam loves to offer a toner when you need a tester and vice versa. Toner = where does it go. Tester = is it wired right."
}
];
</script>
