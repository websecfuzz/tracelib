import posixpath
import os

from itertools import product
from urllib.parse import urlparse, urlunparse
from bs4          import BeautifulSoup
from typing       import Set, List, Dict

from .misc        import get_logger, query_to_dict
from .types       import HTTPMethod, UrlType
from .node        import Node

class Parser:
    @staticmethod
    def parse(node: Node, soup: BeautifulSoup) -> Set[Node]:
        form_links = Parser.parse_forms(soup, node)
        a_links = Parser.parse_anchors(soup, node)

        return a_links | form_links

    @staticmethod
    def parse_anchors(html: BeautifulSoup, called_node: Node) -> Set[Node]:
        """
        Extract href links and their parameters.
        """
        logger = get_logger(__name__)
        logger.debug("==> Extracting <a> links from html")

        links: Set[Node] = set()

        for anchor in html.findAll('a'):
            logger.debug("==> link parsing: %s", anchor)

            url_obj = urlparse(anchor.get('href') or "")

            if not Parser.is_same_domain(url_obj, called_node.url_object):
                continue

            url_obj = Parser.normalise_url(called_node.url_object, url_obj)

            links.add(Node(url=url_obj,
                           method=HTTPMethod.GET))

        logger.debug("==> got new links: %s", links)
        return links

    @staticmethod
    def parse_forms(html: BeautifulSoup, called_node: Node) -> Set[Node]:
        """
        Extract action, method and input fields from HTML forms.
        """
        logger = get_logger(__name__)
        logger.debug("==> Extracting data from forms")

        links: Set[Node] = set()

        for form in html.findAll('form'):
            logger.debug("==> Form parsing: %s", form)

            url_obj = urlparse(form.get('action') or "")

            if not Parser.is_same_domain(url_obj, called_node.url_object):
                continue

            url_obj = Parser.normalise_url(called_node.url_object, url_obj)

            get_params = query_to_dict(url_obj.query)

            url: str = urlunparse(url_obj._replace(query=''))

            select_variants: List[Dict[str, List[str]]] = Parser.parse_select_variants(form.findAll('select'))
            inputs: Dict[str, List[str]]    = Parser.parse_input_like(form.findAll('input'))
            buttons: Dict[str, List[str]]   = Parser.parse_buttons(form.findAll('button'))
            textareas: Dict[str, List[str]] = Parser.parse_input_like(form.findAll('textarea'))

            body_params = {}
            body_params.update(inputs)
            body_params.update(buttons)
            body_params.update(textareas)

            method = HTTPMethod[form.get('method', 'GET').upper()]

            for select_params in select_variants:
                variant_get_params = dict(get_params)
                variant_body_params = dict(body_params)
                variant_body_params.update(select_params)

                if method == HTTPMethod.GET:
                    variant_get_params.update(variant_body_params)
                    variant_body_params = {}

                logger.debug("==> Form get: %s", variant_get_params)
                logger.debug("==> Form body: %s", variant_body_params)

                links.add(Node(url=url,
                               method=method,
                               params={HTTPMethod.GET: variant_get_params, HTTPMethod.POST: variant_body_params}))

        logger.debug("==> Got new links: %s", links)
        return links

    @staticmethod
    def parse_input_like(inputs: List) -> Dict[str, List[str]]:
        result: Dict[str, List[str]] = {}

        for html_input in inputs:

            name: str = html_input.get('name', '')
            if not name:
                continue

            value: str = html_input.get('value', '')
            if not value:

                option = html_input.find('option')
                if option:
                    value: str = option.get('value', '')

            if name in result:
                result[name].append(value)
            else:
                result[name] = [value]

        return result

    @staticmethod
    def parse_buttons(buttons: List) -> Dict[str, List[str]]:
        result: Dict[str, List[str]] = {}

        for button in buttons:
            button_type = (button.get('type') or 'submit').lower()
            if button_type != 'submit':
                continue

            name: str = button.get('name', '')
            if not name:
                continue

            value: str = button.get('value', '')
            if name in result:
                result[name].append(value)
            else:
                result[name] = [value]

        return result

    @staticmethod
    def parse_select_variants(selects: List) -> List[Dict[str, List[str]]]:
        choices: List[tuple[str, List[str]]] = []

        for select in selects:
            name: str = select.get('name', '')
            if not name:
                continue

            values: List[str] = []
            for option in select.findAll('option'):
                value = option.get('value')
                if value is None:
                    value = option.get_text()
                values.append(value)

            if not values:
                values = ['']

            values = list(dict.fromkeys(values))
            choices.append((name, values))

        if not choices:
            return [{}]

        max_variants = int(os.environ.get("WEBFUZZ_MAX_SELECT_VARIANTS", "256"))
        variants: List[Dict[str, List[str]]] = []
        for idx, selected_values in enumerate(product(*[values for _, values in choices])):
            if idx >= max_variants:
                break

            params: Dict[str, List[str]] = {}
            for (name, _), value in zip(choices, selected_values):
                params.setdefault(name, []).append(value)
            variants.append(params)

        return variants or [{}]

    @staticmethod
    def is_same_domain(url1: UrlType, url2: UrlType) -> int:
        if not url1.netloc or not url2.netloc:

            return True
        if url1.netloc == url2.netloc:
            return True
        return False

    @staticmethod
    def relative_to_absolute(base_url:UrlType, relative_url:UrlType) -> UrlType:
        """
        Converts a relative url to an absolute.
        e.g. href="action.php" called from http://localhost/api/login.php
        should be: http://localhost/api/action.php
        """
        if not base_url.path:

            prefix = "/"
        else:
            prefix = base_url.path[0:base_url.path.rfind("/")] + "/"

        return relative_url._replace(path=prefix + relative_url.path)

    @staticmethod
    def set_default_query(base_url:UrlType, target_url: UrlType) -> UrlType:
        """
        Replace query field of url_obj with the query string of the self.node.
        Essentially it returns the same address of self.node).
        """
        return target_url._replace(query=base_url.query)

    @staticmethod
    def set_default_path(base_url:UrlType, target_url: UrlType) -> UrlType:
        """
        Replace url_obj path with the path of calling node.
        """
        return target_url._replace(path=base_url.path)

    @staticmethod
    def set_default_domain(base_url: UrlType, target_url: UrlType) -> UrlType:
        """
        Set the netloc and scheme of target_url as that of base_url
        """
        return target_url._replace(scheme=base_url.scheme, netloc=base_url.netloc)

    @staticmethod
    def remove_dot_segments(path: str) -> str:
        """
        Collapse '.'/'..' segments in a URL path (RFC 3986 remove_dot_segments).

        Without this, relative links such as href="../x" from /a/help/ resolve to
        ever-longer distinct paths (/a/help/../x, /a/help/./../../x, ...). Each is a
        new "base", so the per-base crawl cap never bounds them and the crawl never
        terminates (observed on phpbb/drupal). posixpath.normpath never escapes
        above root for an absolute path; we re-add a trailing slash it would strip
        so directory URLs keep their semantics.
        """
        if not path:
            return path
        normalised = posixpath.normpath(path)
        if path.endswith("/") and not normalised.endswith("/"):
            normalised += "/"
        return normalised

    @staticmethod
    def normalise_url(called_url: UrlType, target_url: UrlType) -> UrlType:
        """
        Fixes a URL object as returned from urllib.parse.urlparse.
        It will try to turn it to an absolute url.
        """

        if target_url.netloc:

            return target_url._replace(path=Parser.remove_dot_segments(target_url.path))

        if target_url.path and target_url.path[0] != "/":

            target_url = Parser.relative_to_absolute(called_url, target_url)

        elif not target_url.path:

            target_url = Parser.set_default_path(called_url, target_url)

            if not target_url.query:
                target_url = Parser.set_default_query(called_url, target_url)

        target_url = Parser.set_default_domain(called_url, target_url)

        target_url = target_url._replace(path=Parser.remove_dot_segments(target_url.path))

        return target_url
