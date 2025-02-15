# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

import re
from typing import List

from assertpy.assertpy import assert_that

from lisa.executable import Tool
from lisa.util import LisaException, get_matched_str


class PartitionInfo(object):
    # TODO: Merge with lsblk.PartitionInfo
    def __init__(
        self,
        name: str,
        uuid: str,
        part_uuid: str,
    ):
        self.name = name
        self.uuid = uuid
        self.part_uuid = part_uuid

    def __repr__(self) -> str:
        return f"{self.name} {self.uuid} {self.part_uuid}"

    def __str__(self) -> str:
        return self.__repr__()


class Blkid(Tool):

    # /dev/sda1: LABEL="Temporary Storage" UUID="9ED4084BD408285B" TYPE="ntfs" PARTUUID="03e90eae-01" # noqa: E501
    _get_partition_name = re.compile(r"\s*(?P<name>\S+):.*")

    # /dev/sda1: LABEL="Temporary Storage" UUID="9ED4084BD408285B" TYPE="ntfs" PARTUUID="03e90eae-01" # noqa: E501
    _get_partition_uuid = re.compile(r"\s+UUID=\"(?P<uuid>\S+)\"")

    # /dev/sda1: LABEL="Temporary Storage" UUID="9ED4084BD408285B" TYPE="ntfs" PARTUUID="03e90eae-01" # noqa: E501
    _get_partition_part_uuid = re.compile(r"\s+PARTUUID=\"(?P<part_uuid>\S+)\"")

    @property
    def command(self) -> str:
        return "blkid"

    def get_partition_information(self) -> List[PartitionInfo]:
        """
        Get partition information from blkid output.
        Sample output :
        /dev/sda1: LABEL="cloudimg-rootfs" UUID="b1983cef-43a3-46ac-a083-b5e06a61c9fd" TYPE="ext4" PARTUUID="6b003b9b-0531-41bb-ab5e-b2491580c31f" # noqa: E501
        /dev/sda15: LABEL_FATBOOT="UEFI" LABEL="UEFI" UUID="0BC7-08EF" TYPE="vfat" PARTUUID="d80ae19a-00f8-4cae-a95e-9bbb761b7e9a" # noqa: E501
        /dev/sdb1: UUID="a88b3ef7-ddc8-4942-8931-253a5f21cae1" TYPE="ext4" PARTUUID="c7c91a5e-01" # noqa: E501
        /dev/loop0: TYPE="squashfs"
        """
        output = self.run(sudo=True).stdout
        partition_info: List[PartitionInfo] = []
        for line in output.splitlines():
            # get partition name
            name = get_matched_str(line, self._get_partition_name)
            assert_that(name, "partition name should not be none.").is_not_none()

            # get partion uuid. This could be None.
            uuid = get_matched_str(line, self._get_partition_uuid)

            # get partion part_uuid. This could be None.
            part_uuid = get_matched_str(line, self._get_partition_part_uuid)

            partition_info.append(PartitionInfo(name, uuid, part_uuid))

        return partition_info

    def get_partition_info_by_name(self, partition_name: str) -> PartitionInfo:
        """
        Get partition information for partition name.
        """
        partition_info = self.get_partition_information()
        for partition in partition_info:
            if partition.name == partition_name:
                return partition

        raise LisaException(f"Partition {partition_name} not found in {partition_info}")
