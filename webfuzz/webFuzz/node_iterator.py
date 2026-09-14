"""
    A Node_list is responsible for inserting new nodes, bookkeeping for the visited links (for the crawler),
    and retrieving the most favorable node.

    A node should be retrieved and added here
    only through its methods (get_next_request(), add) in order to preserve the ordering
"""

import heapq
import os

from typing         import Dict, List, Set, Optional
import random

from .node          import Node
from .types         import CFGTuple, HTTPMethod, List, Label, CFG, Policy, get_logger, FeedbackMode
from .environment   import env

MIN_CORPUS_SEEDS = int(os.environ.get("WEBFUZZ_MIN_CORPUS_SEEDS", "10"))

class NodeIterator:
    """
        Constructs a heap tree of nodes plus a bunch of other data structures
        The heap tree (self._node_list) is semi-ordered in descending order of
        favorableness. self._node_list[0] is the currently most favorable node

        :param crawler_unseen: links that have never been called yet
        :type crawler_unseen: Set of Nodes
        :return: The NodeList object
        :rtype: NodeList
    """
    def __init__(self):
        self.node_list: List[Node] = []
        self._total_cfg_xor: Dict[Label, List[Optional[Node]]] = {}
        self._total_cfg_single: Dict[Label, List[Optional[Node]]] = {}

    @property
    def total_cover_score(self):
        if env.instrument_args.policy == Policy.EDGE:
            total_cfg = self._total_cfg_xor
            total_count = env.instrument_args.edges
        else:
            total_cfg = self._total_cfg_single
            total_count = env.instrument_args.basic_blocks

        return 100*len(total_cfg) / total_count

    def _remove_nodes(self, tobe_removed: Set[Node]):
        logger = get_logger(__name__)

        if len(tobe_removed) == 0:
            return

        prev_len = len(self.node_list)

        self.node_list = list(set(self.node_list) - tobe_removed)

        logger.info("New node replaced %d/%d nodes", \
                    prev_len - len(self.node_list), len(tobe_removed))

        heapq.heapify(self.node_list)

    """
        Add node to the total cfg map

        A new node is accepted only if any of the conditions hold:
            1) has visited a label-bucket that we have not seen before
            2) it visited a label-bucket in which we have seen the past,
               but the node that visited that label is heavier than this
               new node (in terms of response time and size, see Node.isLighterThan)

        :param new_node: the node to add
        :type new_node: Node
        :param local_cfg: the xor-CFG of the node
        :type local_cfg: CFG
    """
    def _add_node_to_total_cfg(self, new_node: Node, local_cfg: CFG) -> None:

        if env.instrument_args.policy == Policy.NODE:
            total_cfg = self._total_cfg_single
        else:
            total_cfg = self._total_cfg_xor

        tobe_removed = set()
        for label, bucket in local_cfg.items():

            if label not in total_cfg:
                nodes: List[Optional[Node]] = [None,None,None,None,None,None,None,None,None]
                nodes[bucket] = new_node
                total_cfg[label] = nodes
                new_node.ref_count += 1
                continue

            existing_node = total_cfg[label][bucket]

            if existing_node is None:
                total_cfg[label][bucket] = new_node
                new_node.ref_count += 1

            elif new_node.is_lighter_than(existing_node):
                existing_node.ref_count -= 1
                if existing_node.ref_count == 0:
                    tobe_removed.add(existing_node)

                new_node.ref_count += 1
                total_cfg[label][bucket] = new_node

        self._remove_nodes(tobe_removed)

    """
        Add new node to the heap tree and to the global CFG map.

        :param new_node: the node to add
        :type new_node: Node
        :param node_cfg: the CFGs observed for this node
        :type node_cfg: CFGTuple
        :return: if the node has been accepted
        :rtype: bool
    """
    def _seed_floor(self, new_node: Node, reason: str) -> bool:
        """Admit `new_node` anyway if the corpus is still below the seed floor.

        Returns True when the node was admitted as a seed."""
        if MIN_CORPUS_SEEDS <= 0 or len(self.node_list) >= MIN_CORPUS_SEEDS:
            return False
        logger = get_logger(__name__)
        new_node.ref_count += 1
        heapq.heappush(self.node_list, new_node)
        logger.info("[seed floor] %s, but corpus has only %d/%d seeds; "
                    "admitting anyway", reason, len(self.node_list), MIN_CORPUS_SEEDS)
        return True

    def add(self, new_node: Node, node_cfg: CFGTuple):
        logger = get_logger(__name__)

        max_corpus = getattr(env.args, "max_corpus_size", 0) if env.args is not None else 0
        if max_corpus and len(self.node_list) >= max_corpus:
            logger.info("corpus full (%d >= %d), not adding node",
                        len(self.node_list), max_corpus)
            return False

        if env.args is not None and env.args.feedback_mode == FeedbackMode.BLACKBOX:
            new_node.ref_count += 1
            heapq.heappush(self.node_list, new_node)
            logger.info("[blackbox] accepted node, list length: %d", len(self.node_list))
            return True

        if env.args is not None and env.args.feedback_mode == FeedbackMode.TRACELIB:
            novelty = getattr(env.args, "tracelib_novelty", "bucket")
            unit = "edges" if novelty == "index" else "edge/bucket pairs"
            refs_before = new_node.ref_count

            if novelty == "index":
                novel_cfg = {label: bucket for label, bucket in node_cfg.xor_cfg.items()
                             if label not in self._total_cfg_xor}
                if not novel_cfg:
                    if self._seed_floor(new_node, "no new bitmap edges"):
                        return True
                    logger.info("[tracelib] no new bitmap edges, not adding node")
                    return False
                self._add_node_to_total_cfg(new_node, novel_cfg)
            else:

                self._add_node_to_total_cfg(new_node, node_cfg.xor_cfg)

            if new_node.ref_count == 0:
                if self._seed_floor(new_node, "no novel %s" % unit):
                    return True
                logger.info("[tracelib] no novel %s, not adding node", unit)
                return False

            heapq.heappush(self.node_list, new_node)
            logger.info("[tracelib] accepted node with %d novel %s, list length: %d",
                        new_node.ref_count - refs_before, unit, len(self.node_list))
            logger.debug("List dump %s", self.node_list)
            return True

        if env.instrument_args.policy == Policy.NODE_EDGE:
            for label in node_cfg.single_cfg.keys():
                self._total_cfg_single[label] = []

        if env.instrument_args.policy == Policy.NODE:
            self._add_node_to_total_cfg(new_node, node_cfg.single_cfg)
        else:
            self._add_node_to_total_cfg(new_node, node_cfg.xor_cfg)

        if new_node.ref_count == 0:
            if self._seed_floor(new_node, "node not favorable"):
                return True
            logger.info("New node not favorable, not adding it")
            return False
        else:

            heapq.heappush(self.node_list, new_node)

            logger.info("New list length: %d", len(self.node_list))
            logger.debug("List dump %s", self.node_list)
            return True

    def __iter__(self):
        return self

    """
        Get the next node to send a request to.
        New unseen requests have the highest priority.
        Otherwise we pick the most favorable already
        visited node, mutate it and return the result

        :return: the next request to sent
        :rtype: Node
    """
    def __next__(self):
        logger = get_logger(__name__)

        if len(self.node_list) == 0:
            logger.error("No more links to follow found.")
            raise StopIteration

        node = heapq.heappop(self.node_list)

        node.picked_score += 1

        heapq.heappush(self.node_list, node)

        return node
