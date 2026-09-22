import json
import unittest
from terminal_review import validate_verdict, review


class ReviewTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
