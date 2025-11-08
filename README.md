# Mikrotik DHCP to Technitium DNS 

This RouterOS script's **primary purpose is to provide Dynamic DNS (DDNS) synchronization to an External DNS Server** (like Technitium DNS) via an HTTP API.

It uses the MikroTik's internal DNS cache (/ip dns static) as a **temporary, authoritative synchronization store** to maintain state and perform change detection. The main goal is to ensure devices receiving dynamic IP addresses are immediately resolvable by their human-assigned names network-wide.

I run this script on a schedule, every 20 mins or so.

## **Key Features**

* **Primary External Sync:** Designed specifically to push and delete records on a configured **External DNS Server**.  
* **Hostname Priority:** Prioritizes hostnames based on administrative needs:  
  1. **DHCP Lease Comment** (Highest Priority, for static assignments/friendly names)  
  2. **DHCP Host-Name** (Provided by the client device)  
  3. **IP Fallback** (E.g., 192-168-1-5 if no name is available)  
* **Generic Hostname Handling:** Detects common, generic hostnames (e.g., *iphone*, *android*, *macbook*, *windows*, *macmini*, etc.) and automatically appends part of the device’s MAC address to make them unique.  
  *Example: `iphone` → `iphone-ddee`*  
* **DNS Cleanup:** Automatically removes stale DNS entries from both the router's internal cache and the **external DNS server** when a lease expires or is no longer active.  
* **External Integration:** Includes logic to update a specified external DNS server using a simple HTTP API (e.g., DNS manager, Pi-hole, or other custom APIs).  
* **Low Impact:** Only updates records that have changed, minimizing write operations.  
* **Logging Control:** Includes a boolean flag (enableLogging) to easily toggle verbose logging for debugging or silence the script during production.

## **Configuration**

Before running the script, you must set the following variables at the top of the file:

| Variable | Description |
| :---- | :---- |
| :local DnsServer | The IP and port of your external DNS API server (e.g., "192.168.8.2:5380").  |
| :local ApiToken | The security token required by your external DNS API. |
| :local enableLogging | Set to true to enable detailed logging for troubleshooting; set to false for silent operation (recommended for scheduled runs). |

---

## **Recommendations**

While the script automatically normalizes hostnames to lowercase and handles generic names gracefully, **the best practice is still to assign static IPs and define meaningful names in the DHCP lease comment field**.

Using the comment field:
- Ensures predictable, human-readable hostnames in DNS.
- Avoids reliance on device-supplied hostnames, which are often inconsistent (especially for phones and tablets).
- Provides a stable mapping even if the device’s DHCP-reported name changes.


