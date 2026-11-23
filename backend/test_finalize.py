"""Handler tests using in-memory bodies; no providers, sockets, or private data."""
import io
import unittest
from unittest.mock import patch
import server


class FinalizeTests(unittest.TestCase):
    def setUp(self):
        server.recordings.clear()
        self.key = patch.object(server, 'MISTRAL_KEY', 'test')
        self.key.start()
        self.addCleanup(self.key.stop)
        self.addCleanup(server.recordings.clear)

    def request(self, sequence, body=b'\0'*4, count=None, **headers):
        handler = object.__new__(server.Handler)
        handler.headers = {'X-Chunk-Sequence': str(sequence),
                           'X-Chunk-Count': str(sequence + bool(body) if count is None else count),
                           'Content-Length': str(len(body)), 'X-Audio-Format': 'pcm-float32',
                           'X-Sample-Rate': '16000', **headers}
        handler.rfile = io.BytesIO(body)
        handler._send_json = lambda status, payload: setattr(handler, 'response', (status, payload))
        handler._accept_recording = lambda rid, rec, target: setattr(handler, 'accepted', (rec, target))
        handler._handle_finalize('test')
        return handler

    def seed(self, chunks):
        server.recordings['test'] = {'chunks': chunks, 'format': 'pcm-float32',
                                     'total_bytes': sum(map(len, chunks.values()))}

    def test_short_recording_with_no_prior_upload(self):
        h = self.request(0, **{'X-Delivery-Target': 'matrix'})
        self.assertEqual(h.accepted, ({'chunks': {0: b'\0'*4}, 'format': 'pcm-float32'}, 'matrix'))

    def test_final_chunk_appends_and_removes_spool(self):
        self.seed({0: b'abcd'})
        h = self.request(1)
        self.assertEqual(h.accepted[0]['chunks'], {0: b'abcd', 1: b'\0'*4})
        self.assertNotIn('test', server.recordings)

    def test_empty_tail(self):
        self.seed({0: b'abcd'})
        self.assertEqual(self.request(1, body=b'').accepted[0]['chunks'], {0: b'abcd'})

    def test_missing_trailing_upload_rejected_without_losing_spool(self):
        self.seed({0: b'abcd'})
        self.assertEqual(self.request(2).response[0], 409)
        self.assertIn('test', server.recordings)

    def test_gap_and_unexpected_chunks_rejected(self):
        for chunks in ({1: b'abcd'}, {0: b'abcd', 1: b'efgh'}):
            self.seed(chunks)
            self.assertEqual(self.request(1).response[0], 409)

    def test_bad_metadata_rejected(self):
        for seq, count, body in [(-1, 0, b'abcd'), (0, 2, b'abcd'), (0, 0, b''),
                                 (0, 1, b'abc'), ('bad', 1, b'abcd')]:
            self.assertEqual(self.request(seq, count=count, body=body).response[0], 400)

    def test_size_cap_and_format(self):
        self.seed({0: b'abcd'})
        with patch.object(server, 'MAX_BYTES', 4):
            self.assertEqual(self.request(1).response[0], 400) # count exceeds capacity
        self.assertEqual(self.request(1, **{'X-Audio-Format': 'aac-adts'}).response[0], 400)
        self.seed({0: b'abcdefgh'})
        with patch.object(server, 'MAX_BYTES', 8):
            self.assertEqual(self.request(1).response[0], 413)

    def test_truncated_body(self):
        self.assertEqual(self.request(0, **{'Content-Length': '8'}).response[0], 400)

    def test_acceptance_precedes_worker_and_registers_liveness(self):
        h = object.__new__(server.Handler)
        h.client_address = ('127.0.0.1', 1)
        events = []
        h._send_json = lambda status, payload: events.append(status)
        with patch.object(server, 'register_processing', side_effect=lambda *a: events.append('registered')), \
             patch.object(server.threading, 'Thread') as worker:
            worker.return_value.start.side_effect = lambda: events.append('worker')
            h._accept_recording('test', {'chunks': {0: b'abcd'}, 'format': 'pcm-float32'}, '')
        self.assertEqual(events, ['registered', 202, 'worker'])

    def test_legacy_submit_remains_supported(self):
        self.seed({0: b'abcd'})
        h = object.__new__(server.Handler)
        h.headers = {}
        h._accept_recording = lambda *args: setattr(h, 'accepted', True)
        h._handle_submit('test')
        self.assertTrue(h.accepted)


class FinalizeHTTPTests(unittest.TestCase):
    def test_http_action_accepts_final_audio_without_waiting_for_worker(self):
        import http.client
        import threading
        from http.server import ThreadingHTTPServer
        release = threading.Event()
        started = threading.Event()
        finished = threading.Event()
        observed = []
        def worker(rid, audio, fmt, target):
            observed.append((audio, fmt, target))
            started.set()
            release.wait(5)
            server.unregister_processing(rid)
            finished.set()
        with patch.object(server, 'API_KEY', 'test-key'), \
             patch.object(server, 'MISTRAL_KEY', 'test-key'), \
             patch.object(server, 'process_recording', side_effect=worker):
            httpd = ThreadingHTTPServer(('127.0.0.1', 0), server.Handler)
            thread = threading.Thread(target=httpd.serve_forever)
            thread.start()
            connection = http.client.HTTPConnection(*httpd.server_address, timeout=2)
            try:
                connection.request('POST', '/audio', body=b'abcd', headers={
                    'Authorization': 'Bearer test-key', 'X-Recording-ID': 'http-test',
                    'X-Action': 'finalize', 'X-Chunk-Sequence': '0', 'X-Chunk-Count': '1',
                    'X-Audio-Format': 'pcm-float32', 'X-Sample-Rate': '16000',
                    'X-Delivery-Target': 'matrix'})
                response = connection.getresponse()
                self.assertEqual(response.status, 202)
                self.assertIn(b'accepted', response.read())
                self.assertTrue(started.wait(2))
                self.assertFalse(finished.is_set())
                self.assertEqual(observed, [(b'abcd', 'pcm-float32', 'matrix')])
            finally:
                release.set()
                connection.close()
                httpd.shutdown()
                httpd.server_close()
                thread.join()
                finished.wait(2)
