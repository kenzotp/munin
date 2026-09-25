# Tests for the /fints/transactions FinTS section of app.py.
#
# HARD RULE: none of this ever talks to a real bank. FinTS3PinTanClient is
# always monkeypatched to a FakeClient built entirely from synthetic data;
# credentials here are dummy strings, never real ones.
import types
import unittest
from unittest.mock import patch

import app as appmod
from fastapi import HTTPException
from fints.client import NeedTANResponse
from fints.exceptions import FinTSClientPINError, FinTSClientTemporaryAuthError
from fints.utils import mt940_to_array

# A synthetic MT940 statement: one negative-amount transaction with a
# NOTPROVIDED end-to-end reference and a plain-string purpose. None of the
# values (BLZ, IBAN, names) are real.
MT940_SAMPLE = (
    ":20:STARTUMS\r\n"
    ":25:DE00123456780000000000\r\n"
    ":28C:1\r\n"
    ":60F:C260101EUR1000,00\r\n"
    ":61:2601150115DR19,99NMSCNONREF\r\n"
    ":86:108?00Lastschrift?20EREF+NOTPROVIDEDSVWZ+Invoice 42?32Test GmbH\r\n"
    ":62F:C260115EUR980,01\r\n"
    "-\r\n"
)

PIN_VALUE = "dummy-test-pin-never-real"


def payload():
    return appmod.FinTSIn(
        blz="00000000",
        url="https://example.invalid/fints",
        login="dummy-test-login",
        pin=PIN_VALUE,
        product_id="TEST",
        start="2026-01-01",
        end="2026-01-31",
    )


def need_tan(decoupled=True):
    return NeedTANResponse(
        command_seg=None,
        tan_request=types.SimpleNamespace(challenge="Approve in app"),
        decoupled=decoupled,
    )


class FakeAccount:
    def __init__(self, iban):
        self.iban = iban
        self.type = "checking"


class FakeMechanism:
    def __init__(
        self,
        name="pushTAN 2.0",
        decoupled_max_poll_number=3,
        wait_before_first_poll=0,
        wait_before_next_poll=0,
    ):
        self.name = name
        self.decoupled_max_poll_number = decoupled_max_poll_number
        self.wait_before_first_poll = wait_before_first_poll
        self.wait_before_next_poll = wait_before_next_poll


class FakeClient:
    """Stands in for fints.client.FinTS3PinTanClient. Never touches a bank."""

    def __init__(self, blz, login, pin, url, product_id=None):
        self.blz, self.login, self.pin, self.url = blz, login, pin, url
        self.selected_tan_medium = None
        self.init_tan_response = None
        self._polls = 0
        self.approve_after = 1
        self.accounts = [FakeAccount("DE00TEST00000001")]
        self.account_errors = {}
        self.init_error = None
        self.mech_key = "923"

    # -- TAN mechanism / media --------------------------------------
    def fetch_tan_mechanisms(self):
        pass

    def get_tan_mechanisms(self):
        return {self.mech_key: FakeMechanism()}

    def set_tan_mechanism(self, key):
        self.mech_key = key

    def get_current_tan_mechanism(self):
        return self.mech_key

    def is_tan_media_required(self):
        return False

    def get_tan_media(self):
        return (None, [])

    def set_tan_medium(self, medium):
        self.selected_tan_medium = medium

    # -- dialog --------------------------------------------------------
    def __enter__(self):
        if self.init_error:
            raise self.init_error
        return self

    def __exit__(self, *exc):
        return False

    def get_sepa_accounts(self):
        return self.accounts

    def get_transactions(self, acc, start, end):
        if acc.iban in self.account_errors:
            raise self.account_errors[acc.iban]
        return list(mt940_to_array(MT940_SAMPLE))

    def send_tan(self, response, tan):
        self._polls += 1
        if self._polls >= self.approve_after:
            return "approved"
        return need_tan()


class FintsTransactionsTest(unittest.TestCase):
    def _call(self, fake):
        with patch.object(appmod, "FinTS3PinTanClient", return_value=fake):
            return appmod.fints_transactions(payload())

    def test_approval_after_n_polls_returns_rows(self):
        fake = FakeClient(None, None, None, None)
        fake.approve_after = 2
        fake.init_tan_response = need_tan()
        body = self._call(fake)
        self.assertEqual(len(body["rows"]), 1)
        self.assertEqual(body["accounts"], [{"iban": "DE00TEST00000001", "rows": 1}])

    def test_never_approved_raises_tan_timeout(self):
        fake = FakeClient(None, None, None, None)
        fake.approve_after = 10_000  # unreachable within the mechanism's 3-poll budget
        fake.init_tan_response = need_tan()
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail["tan_timeout"], True)

    def test_masking_pin_block_exception_raises_pin_error(self):
        fake = FakeClient(None, None, None, None)
        fake.init_error = Exception("Refusing to use PIN after block")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail["pin_error"], True)
        self.assertNotIn(PIN_VALUE, str(ctx.exception.detail))

    def test_fints_client_pin_error_raises_pin_error(self):
        fake = FakeClient(None, None, None, None)
        fake.init_error = FinTSClientPINError("blocked")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail["pin_error"], True)

    def test_temporary_auth_error_raises_locked(self):
        fake = FakeClient(None, None, None, None)
        fake.init_error = FinTSClientTemporaryAuthError("locked out")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail["locked"], True)

    def test_typed_tan_challenge_raises_tan_required(self):
        fake = FakeClient(None, None, None, None)
        fake.init_tan_response = need_tan(decoupled=False)
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertEqual(ctx.exception.detail["tan_required"], True)

    def test_account_error_is_skipped_and_reported_not_swallowed(self):
        fake = FakeClient(None, None, None, None)
        fake.accounts = [FakeAccount("DE00TEST00000001"), FakeAccount("DE00TEST00000002")]
        fake.account_errors = {"DE00TEST00000002": RuntimeError("bank says no")}
        body = self._call(fake)
        self.assertEqual(len(body["rows"]), 1)  # only the good account contributed rows
        errored = [a for a in body["accounts"] if a.get("error")]
        self.assertEqual(len(errored), 1)
        self.assertEqual(errored[0]["iban"], "DE00TEST00000002")

    def test_row_mapping_from_synthetic_mt940(self):
        txs = list(mt940_to_array(MT940_SAMPLE))
        row = appmod._row(txs[0], "DE00TEST00000001")
        self.assertEqual(row["iban"], "DE00TEST00000001")
        self.assertEqual(row["amount_cents"], -1999)
        self.assertIsInstance(row["amount_cents"], int)
        self.assertEqual(row["description"], "Invoice 42")
        self.assertIsNone(row["external_id"])  # NOTPROVIDED -> null
        self.assertEqual(row["booked_at"], "2026-01-15")
        self.assertEqual(row["payer"], "Test GmbH")


if __name__ == "__main__":
    unittest.main()
