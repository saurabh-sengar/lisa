# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

import re
from typing import List, Pattern

from lisa import Logger, Node, SkippedException, UnsupportedDistroException
from lisa.nic import NicInfo
from lisa.tools import Echo, Ethtool, Mount
from microsoft.testsuites.xdp.xdpdump import XdpDump

_rx_drop_patterns = [
    # rx_queue_0_xdp_drop
    re.compile(r"^rx_queue_\d+_xdp_drop$"),
    # rx_xdp_drop
    re.compile(r"^rx_xdp_drop$"),
]
_tx_forwarded_patterns = [
    # rx_xdp_tx
    re.compile(r"^rx_xdp_tx$"),
    # rx_xdp_tx_xmit
    re.compile(r"^rx_xdp_tx_xmit$"),
]
_huge_page_disks = {"/mnt/huge": "", "/mnt/huge1g": "pagesize=1G"}


def get_xdpdump(node: Node) -> XdpDump:
    try:
        xdpdump = node.tools[XdpDump]
    except UnsupportedDistroException as identifier:
        raise SkippedException(identifier)

    return xdpdump


def get_forwarded_count(
    node: Node, nic: NicInfo, previous_count: int, log: Logger
) -> int:
    return _aggregate_count(
        node=node,
        nic=nic,
        previous_count=previous_count,
        log=log,
        counter_name="xdp forwarded",
        patterns=_tx_forwarded_patterns,
    )


def get_dropped_count(
    node: Node, nic: NicInfo, previous_count: int, log: Logger
) -> int:
    return _aggregate_count(
        node=node,
        nic=nic,
        previous_count=previous_count,
        log=log,
        counter_name="xdp dropped",
        patterns=_rx_drop_patterns,
    )


def set_hugepage(node: Node) -> None:
    mount = node.tools[Mount]
    for point, options in _huge_page_disks.items():
        mount.mount(disk_name="nodev", point=point, type="hugetlbfs", options=options)
    echo = node.tools[Echo]
    echo.write_to_file(
        "4096",
        node.get_pure_path(
            "/sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages"
        ),
        sudo=True,
    )
    echo.write_to_file(
        "1",
        node.get_pure_path(
            "/sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages"
        ),
        sudo=True,
    )


def remove_hugepage(node: Node) -> None:
    echo = node.tools[Echo]
    echo.write_to_file(
        "0",
        node.get_pure_path(
            "/sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages"
        ),
        sudo=True,
    )
    echo.write_to_file(
        "0",
        node.get_pure_path(
            "/sys/devices/system/node/node0/hugepages/hugepages-1048576kB/nr_hugepages"
        ),
        sudo=True,
    )

    mount = node.tools[Mount]
    for point in _huge_page_disks:
        mount.umount(disk_name="nodev", point=point, type="hugetlbfs", erase=False)
        pure_path = node.get_pure_path(point)
        node.execute(f"rm -rf {pure_path}", sudo=True)


def _aggregate_count(
    node: Node,
    nic: NicInfo,
    previous_count: int,
    log: Logger,
    counter_name: str,
    patterns: List[Pattern[str]],
) -> int:
    ethtool = node.tools[Ethtool]
    nic_names = [nic.upper, nic.lower]

    # aggregate xdp drop count by different nic type
    new_count = -previous_count
    for nic_name in nic_names:
        # there may not have vf nic
        if not nic_name:
            continue
        stats = ethtool.get_device_statistics(interface=nic_name, force_run=True)
        # the name and pattern ordered by syn/vf
        for pattern in patterns:
            items = {key: value for key, value in stats.items() if pattern.match(key)}
            if items:
                log.debug(f"found {counter_name} stats: {items}")
                new_count += sum(value for value in items.values())

    log.debug(f"{counter_name} count: {new_count}")
    return new_count
