#!/usr/bin/env python3
"""Threaded proxy: Hindsight (port 11434) -> llama-server (port 11435).
Repairs malformed JSON in LLM responses (fences, bad escapes, structural issues)."""

import http.server
import socketserver
import urllib.request
import urllib.error
import json
import re
import sys
import traceback

try:
    from json_repair import repair_json
    HAS_REPAIR = True
except ImportError:
    HAS_REPAIR = False
    sys.stderr.write("WARNING: json-repair not installed - falling back to regex fix\n")
    sys.stderr.flush()

LISTEN_PORT   = int(sys.argv[1]) if len(sys.argv) > 1 else 11434
UPSTREAM_PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 11435
UPSTREAM      = f"http://127.0.0.1:{UPSTREAM_PORT}"

MAX_OUTPUT_TOKENS = 1500  # prevents runaway grammar-free generation (2343+ tokens seen)

FENCE_RE       = re.compile(r'^```(?:json)?\s*\n?(.*?)\n?```\s*$', re.DOTALL)
INVALID_ESC_RE = re.compile(r'\\(?!["\\/bfnrtu])', re.UNICODE)

_CONNECTION_ERRORS = (ConnectionAbortedError, BrokenPipeError, ConnectionResetError)


def log_err(msg):
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


def strip_fence(text):
    if not text:
        return text
    m = FENCE_RE.match(text.strip())
    return m.group(1).strip() if m else text


def repair_content(text):
    """Repair model-generated JSON: strip fences, fix escapes and structural issues.
    Also wraps bare fact-lists into {"facts": [...]} so Hindsight gets a dict."""
    text = strip_fence(text)
    if not text:
        return text
    if HAS_REPAIR:
        try:
            repaired = repair_json(text, return_objects=False)
            if repaired:
                text = repaired
        except Exception as e:
            log_err(f"json_repair error: {e}")
    else:
        try:
            json.loads(text)
        except json.JSONDecodeError:
            text = INVALID_ESC_RE.sub(r'\\\\', text)
    # If the model returned a bare list of objects (missing dict wrapper), wrap it.
    try:
        parsed = json.loads(text)
        if isinstance(parsed, list) and parsed and isinstance(parsed[0], dict):
            log_err("Wrapping bare list into {\"facts\": [...]}")
            text = json.dumps({"facts": parsed})
    except (json.JSONDecodeError, IndexError):
        pass
    return text


SKIP_RESP_HEADERS = {'transfer-encoding', 'content-length', 'connection'}


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def _forward(self, method, body=None):
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ('host', 'content-length')}
        req = urllib.request.Request(
            UPSTREAM + self.path, data=body, headers=headers, method=method)
        try:
            resp         = urllib.request.urlopen(req, timeout=600)
            resp_body    = resp.read()
            content_type = resp.getheader('Content-Type', '')

            if 'json' in content_type and 'completions' in self.path:
                try:
                    body_str = resp_body.decode('utf-8', errors='replace')
                    try:
                        data = json.loads(body_str)
                    except json.JSONDecodeError as e:
                        log_err(f"Outer JSON parse failed: {e} - applying escape fix")
                        body_str = INVALID_ESC_RE.sub(r'\\\\', body_str)
                        data = json.loads(body_str)
                    for choice in data.get('choices', []):
                        msg     = choice.get('message', {})
                        content = msg.get('content')
                        if content:
                            fixed = repair_content(content)
                            if fixed != content:
                                log_err(f"Repaired: {content[:80]!r}")
                            msg['content'] = fixed
                    resp_body = json.dumps(data).encode()
                except Exception as e:
                    log_err(f"Fix pipeline failed: {e}\n{traceback.format_exc()}")

            self.send_response(resp.status)
            for k, v in resp.getheaders():
                if k.lower() not in SKIP_RESP_HEADERS:
                    self.send_header(k, v)
            self.send_header('Content-Length', str(len(resp_body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(resp_body)

        except _CONNECTION_ERRORS:
            pass  # client disconnected mid-response - harmless

        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Connection', 'close')
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length)
        # Strip GBNF grammar and JSON-mode constraints so llama generates at full
        # speed (~15 t/s) instead of grammar-constrained speed (~1-4 t/s).
        # The repair_content() pipeline handles any resulting JSON formatting issues.
        if b'completions' in self.path.encode() and body:
            try:
                req_data = json.loads(body)
                changed = False
                for key in ('grammar', 'response_format'):
                    if key in req_data:
                        log_err(f"Stripped '{key}' from request (grammar overhead avoided)")
                        del req_data[key]
                        changed = True
                # Cap max_tokens to avoid runaway generation (proxy fixes truncated JSON)
                if req_data.get('max_tokens', 99999) > MAX_OUTPUT_TOKENS:
                    req_data['max_tokens'] = MAX_OUTPUT_TOKENS
                    changed = True
                if changed:
                    body = json.dumps(req_data).encode()
            except Exception as e:
                log_err(f"Request body rewrite failed: {e}")
        self._forward('POST', body)

    def do_GET(self):
        self._forward('GET')

    def log_message(self, fmt, *args):
        pass


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        if not issubclass(sys.exc_info()[0], _CONNECTION_ERRORS):
            log_err(f"Error from {client_address}:\n{traceback.format_exc()}")


if __name__ == '__main__':
    mode = "json-repair" if HAS_REPAIR else "regex-fallback"
    print(f"llama-proxy [{mode}]: :{LISTEN_PORT} -> {UPSTREAM}", flush=True)
    ThreadedHTTPServer(('0.0.0.0', LISTEN_PORT), ProxyHandler).serve_forever()
