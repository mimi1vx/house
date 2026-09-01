#pragma once
#include <stdint.h>
#include <stddef.h>
#include "virtio_transport.h"

#ifndef HOUSE_VIRTIO_NET
#define HOUSE_VIRTIO_NET 1
#endif

// Virtio-net device id
#define VIRTIO_DEVICE_ID_NET 1

// Feature bits for virtio-net (superset; only VERSION_1|EVENT_IDX required)
#define VIRTIO_NET_F_CSUM 0
#define VIRTIO_NET_F_GUEST_CSUM 1
#define VIRTIO_NET_F_CTRL_GUEST_OFFLOADS 2
#define VIRTIO_NET_F_MAC 5
#define VIRTIO_NET_F_GSO 6
#define VIRTIO_NET_F_GUEST_TSO4 7
#define VIRTIO_NET_F_GUEST_TSO6 8
#define VIRTIO_NET_F_GUEST_ECN 9
#define VIRTIO_NET_F_GUEST_UFO 10
#define VIRTIO_NET_F_HOST_TSO4 11
#define VIRTIO_NET_F_HOST_TSO6 12
#define VIRTIO_NET_F_HOST_ECN 13
#define VIRTIO_NET_F_HOST_UFO 14
#define VIRTIO_NET_F_MRG_RXBUF 15
#define VIRTIO_NET_F_STATUS 16
#define VIRTIO_NET_F_CTRL_VQ 17
#define VIRTIO_NET_F_CTRL_RX 18
#define VIRTIO_NET_F_CTRL_VLAN 19
#define VIRTIO_NET_F_GUEST_ANNOUNCE 21
#define VIRTIO_NET_F_MQ 22
#define VIRTIO_NET_F_CTRL_MAC_ADDR 23
#define VIRTIO_NET_F_NOTIFY_ON_EMPTY 24
#define VIRTIO_NET_F_GUEST_HDRLEN 59

// Header size
#define VIRTIO_NET_HDR_SIZE 12

// Ethernet
#define ETH_ALEN 6
#define ETH_HLEN 14
#define ETH_P_ARP 0x0806
#define ETH_P_IP 0x0800

// ARP
#define ARP_HTYPE_ETH 1
#define ARP_PTYPE_IP 0x0800
#define ARP_OP_REQUEST 1
#define ARP_OP_REPLY 2

// IP
#define IPPROTO_ICMP 1
#define IPPROTO_UDP 17

// DHCP
#define DHCP_CLIENT_PORT 68
#define DHCP_SERVER_PORT 67

// Config offset: MAC at 0x100, status at 0x106
#define VIRTIO_NET_CFG_OFF_MAC 0x100
#define VIRTIO_NET_CFG_OFF_STATUS 0x106
#define VIRTIO_NET_CFG_OFF_MAX_QUEUES 0x108

#define VIRTIO_NET_CTRL_QUEUE 2

// 12-byte virtio_net_hdr (LE, packed)
struct virtio_net_hdr {
    uint8_t flags;
    uint8_t gso_type;
    uint16_t hdr_len;
    uint16_t gso_size;
    uint16_t csum_start;
    uint16_t csum_offset;
    uint16_t num_buffers;
} __attribute__((packed));

// Config layout (subset)
struct virtio_net_config {
    uint8_t mac[6];
    uint16_t status;
    uint16_t max_virtqueue_pairs;
} __attribute__((packed));

// API
int virtio_net_probe_mac(int slot, uint8_t mac[6]);
int virtio_net_submit_rx(int slot, uint64_t data_pa, uint32_t len, uint32_t *req_id);
int virtio_net_submit_tx(int slot, uint64_t hdr_pa, uint64_t data_pa, uint32_t data_len, uint32_t *req_id);
int virtio_net_poll_used(int slot, int qidx, uint32_t *out_id, uint32_t *out_len);
int virtio_net_save_queues(int slot, uint64_t rx_desc, uint64_t rx_avail, uint64_t rx_used, uint64_t tx_desc, uint64_t tx_avail, uint64_t tx_used, uint32_t qsize_rx, uint32_t qsize_tx);
void virtio_net_invalidate(uint64_t pa, size_t len);
