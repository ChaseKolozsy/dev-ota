import json
import io
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from terminal_review import validate_verdict, review, main


class ReviewTests(unittest.TestCase):
    def test_service_failure_emits_retry_flag_without_exception_details(self):
        output = io.StringIO()
        with patch('terminal_review.sys.stdin', SimpleNamespace(buffer=io.BytesIO(b'{"text":"hello"}'))), \
             patch('terminal_review.sys.stdout', output), \
             patch('terminal_review.review', side_effect=TimeoutError('private diagnostic')):
            main()
        value = json.loads(output.getvalue())
        self.assertTrue(value['retryable'])
        self.assertEqual(value['status'], 'uncertain')
        self.assertNotIn('private diagnostic', output.getvalue())

    def test_success_requires_quote_present_in_source(self):
        source = 'Final answer: All requested work is complete. All checks passed.'
        verdict = {'status': 'reported_success', 'reason': 'Reports completion and passing checks.',
                   'evidence': 'All requested work is complete. All checks passed.'}
        self.assertEqual(validate_verdict(json.dumps(verdict), source)['status'], 'reported_success')
        verdict['evidence'] = 'Fabricated success quote'
        self.assertEqual(validate_verdict(json.dumps(verdict), source)['status'], 'uncertain')

    def test_wrong_types_and_unknown_status_fail_closed(self):
        for value in [[], {'status': True, 'reason': 'done', 'evidence': 'done'},
                      {'status': 'reported_success', 'reason': 'done', 'evidence': ''},
                      {'status': 'reported_success', 'reason': 7, 'evidence': 'done'}]:
            self.assertEqual(validate_verdict(json.dumps(value), 'done')['status'], 'uncertain')

    def test_empty_or_oversized_input_never_calls_model(self):
        for source in ['', None, 'a' * 10001]:
            self.assertEqual(review(source)['status'], 'uncertain')

    def test_invalid_assessment_is_retryable_but_ambiguous_text_is_not(self):
        for reply in ['not json', '{}', json.dumps({'status': 'reported_success',
                'reason': 'Done', 'evidence': 'invented quote'})]:
            value = validate_verdict(reply, 'Still working')
            self.assertEqual(value['status'], 'uncertain')
            self.assertTrue(value['retryable'])
        value = validate_verdict(json.dumps({'status': 'uncertain',
            'reason': 'Still working', 'evidence': ''}), 'Still working')
        self.assertFalse(value.get('retryable', False))


if __name__ == '__main__':
    unittest.main()
