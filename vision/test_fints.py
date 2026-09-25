# Tests for the /fints/transactions FinTS section of app.py.
#
# HARD RULE: none of this ever talks to a real bank. FinTS3PinTanClient is
# always monkeypatched to a FakeClient built entirely from synthetic data;
# credentials here are dummy strings, never real ones.
import base64
import json
import types
import unittest
from unittest.mock import patch

import app as appmod
from fastapi import HTTPException
from fints.client import DATA_BLOB_MAGIC, SYSTEM_ID_UNASSIGNED, FinTS3PinTanClient, NeedTANResponse
from fints.exceptions import FinTSClientPINError, FinTSClientTemporaryAuthError, FinTSDialogInitError
from fints.utils import decompress_datablob, mt940_to_array

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


def payload(client_state=None):
    return appmod.FinTSIn(
        blz="00000000",
        url="https://example.invalid/fints",
        login="dummy-test-login",
        pin=PIN_VALUE,
        product_id="TEST",
        start="2026-01-01",
        end="2026-01-31",
        client_state=client_state,
    )


def fake_state(mech_key="923", selected_tan_medium=None, system_id="fake-system-id"):
    """A base64 client_state string a FakeClient can restore from — not real
    python-fints wire format, just what FakeClient.__init__(from_data=...)
    and FakeClient.deconstruct() agree on between themselves."""
    raw = json.dumps(
        {"mech_key": mech_key, "selected_tan_medium": selected_tan_medium, "system_id": system_id}
    ).encode()
    return base64.b64encode(raw).decode()


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
    """Stands in for fints.client.FinTS3PinTanClient. Never touches a bank.

    Unlike the real client, state is (de)serialized with plain JSON via
    fake_state()/deconstruct() — the point of these tests is app.py's
    bootstrap-skip and client_state-passing logic, not python-fints' own wire
    format (that round trip is covered separately against the real class)."""

    def __init__(self, blz, login, pin, url, product_id=None, from_data=None):
        self.blz, self.login, self.pin, self.url = blz, login, pin, url
        self.selected_tan_medium = None
        self.init_tan_response = None
        self._polls = 0
        self.approve_after = 1
        self.accounts = [FakeAccount("DE00TEST00000001")]
        self.account_errors = {}
        self.init_error = None
        self.mech_key = None
        self.system_id = SYSTEM_ID_UNASSIGNED
        self.fetch_tan_mechanisms_calls = 0
        self.tan_media_calls = 0
        if from_data:
            restored = json.loads(from_data)
            self.mech_key = restored.get("mech_key")
            self.selected_tan_medium = restored.get("selected_tan_medium")
            self.system_id = restored.get("system_id") or self.system_id

    # -- TAN mechanism / media --------------------------------------
    def fetch_tan_mechanisms(self):
        self.fetch_tan_mechanisms_calls += 1
        self.mech_key = self.mech_key or "923"
        if self.system_id == SYSTEM_ID_UNASSIGNED:
            self.system_id = "fake-system-id"

    def get_tan_mechanisms(self):
        return {"923": FakeMechanism()}

    def set_tan_mechanism(self, key):
        self.mech_key = key

    def get_current_tan_mechanism(self):
        return self.mech_key

    def is_tan_media_required(self):
        return False

    def get_tan_media(self):
        self.tan_media_calls += 1
        return (None, [])

    def set_tan_medium(self, medium):
        self.selected_tan_medium = medium

    def deconstruct(self, including_private=False):
        return json.dumps(
            {
                "mech_key": self.mech_key,
                "selected_tan_medium": self.selected_tan_medium,
                "system_id": self.system_id,
            }
        ).encode()

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
    def _call(self, fake, client_state=None):
        with patch.object(appmod, "FinTS3PinTanClient", return_value=fake):
            return appmod.fints_transactions(payload(client_state=client_state))

    def _call_capturing(self, fake, client_state=None):
        """Like _call, but also returns the mock so a test can inspect what
        kwargs app.py actually passed to the (would-be) client constructor."""
        with patch.object(appmod, "FinTS3PinTanClient", return_value=fake) as mock:
            body = appmod.fints_transactions(payload(client_state=client_state))
        return body, mock

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

    # ---------------------------------------------------------- S1/S2 state

    def test_no_client_state_bootstraps_as_before(self):
        fake = FakeClient(None, None, None, None)
        body, mock = self._call_capturing(fake)
        self.assertIsNone(mock.call_args.kwargs.get("from_data"))
        self.assertEqual(fake.fetch_tan_mechanisms_calls, 1)
        self.assertEqual(len(body["rows"]), 1)
        # Success always reports back a state now (system ID was assigned
        # during the bootstrap), but that's additive — nothing above changed.
        self.assertIn("client_state", body)

    def test_client_state_with_mechanism_skips_bootstrap_and_medium_selection(self):
        state = fake_state(mech_key="923", selected_tan_medium="M1", system_id="87654321")
        raw = base64.b64decode(state)
        fake = FakeClient(None, None, None, None, from_data=raw)
        body, mock = self._call_capturing(fake, client_state=state)

        self.assertEqual(mock.call_args.kwargs.get("from_data"), raw)
        self.assertEqual(fake.fetch_tan_mechanisms_calls, 0)
        self.assertEqual(fake.tan_media_calls, 0)
        self.assertEqual(len(body["rows"]), 1)

    def test_restored_state_without_mechanism_bootstraps_as_before(self):
        state = fake_state(mech_key=None, selected_tan_medium=None, system_id=SYSTEM_ID_UNASSIGNED)
        raw = base64.b64decode(state)
        fake = FakeClient(None, None, None, None, from_data=raw)
        body, mock = self._call_capturing(fake, client_state=state)

        self.assertEqual(fake.fetch_tan_mechanisms_calls, 1)
        self.assertEqual(len(body["rows"]), 1)

    def test_success_returns_client_state_from_data_from_accepts(self):
        fake = FakeClient(None, None, None, None)
        body = self._call(fake)
        self.assertIn("client_state", body)
        # What comes back is exactly what a from_data= on the next request
        # would decode: base64(deconstruct()).
        decoded = json.loads(base64.b64decode(body["client_state"]))
        self.assertEqual(decoded, json.loads(fake.deconstruct()))

    def test_stale_restored_state_gets_state_invalid_hint(self):
        state = fake_state(mech_key="923", system_id="87654321")
        raw = base64.b64decode(state)
        fake = FakeClient(None, None, None, None, from_data=raw)
        fake.init_error = FinTSDialogInitError("Couldn't establish dialog with bank")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake, client_state=state)
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertNotIn("pin_error", ctx.exception.detail)
        self.assertNotIn("locked", ctx.exception.detail)
        self.assertEqual(ctx.exception.detail["state_invalid"], True)

    def test_same_dialog_init_error_without_restored_state_has_no_hint(self):
        fake = FakeClient(None, None, None, None)
        fake.init_error = FinTSDialogInitError("Couldn't establish dialog with bank")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)  # no client_state at all
        self.assertEqual(ctx.exception.status_code, 502)
        self.assertNotIn("state_invalid", ctx.exception.detail)

    def test_sidecar_never_retries_on_stale_state(self):
        # Same fixture as the state_invalid test, but the point here is that
        # the bank is contacted exactly once — bail() raises straight away,
        # nothing in app.py loops or re-tries with a fresh dialog.
        state = fake_state(mech_key="923", system_id="87654321")
        raw = base64.b64decode(state)
        fake = FakeClient(None, None, None, None, from_data=raw)
        fake.init_error = FinTSDialogInitError("stale")
        enter_calls = []
        real_enter = FakeClient.__enter__

        def counting_enter(self):
            enter_calls.append(1)
            return real_enter(self)

        with patch.object(FakeClient, "__enter__", counting_enter):
            with self.assertRaises(HTTPException):
                self._call(fake, client_state=state)
        self.assertEqual(len(enter_calls), 1)

    def test_pin_error_on_restored_state_stays_pin_error_not_state_invalid(self):
        # PIN/lock errors are checked before the state_invalid heuristic, so a
        # real PIN problem is never misreported as a stale-state problem.
        state = fake_state(mech_key="923", system_id="87654321")
        raw = base64.b64decode(state)
        fake = FakeClient(None, None, None, None, from_data=raw)
        fake.init_error = FinTSClientPINError("blocked")
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake, client_state=state)
        self.assertEqual(ctx.exception.detail["pin_error"], True)
        self.assertNotIn("state_invalid", ctx.exception.detail)

    def test_tan_timeout_includes_client_state_once_system_id_assigned(self):
        fake = FakeClient(None, None, None, None)
        fake.approve_after = 10_000
        fake.init_tan_response = need_tan()
        with self.assertRaises(HTTPException) as ctx:
            self._call(fake)
        # fetch_tan_mechanisms() (called before the TAN wait) already assigned
        # a system ID, so the timeout response can still hand back state.
        self.assertIn("client_state", ctx.exception.detail)
        decoded = json.loads(base64.b64decode(ctx.exception.detail["client_state"]))
        self.assertEqual(decoded["system_id"], fake.system_id)

    def test_client_state_helper_returns_none_without_a_system_id(self):
        fake = FakeClient(None, None, None, None)
        self.assertEqual(fake.system_id, SYSTEM_ID_UNASSIGNED)
        self.assertIsNone(appmod._client_state(fake))

    def test_client_state_helper_encodes_deconstruct_with_a_system_id(self):
        fake = FakeClient(None, None, None, None)
        fake.system_id = "12345678"
        fake.mech_key = "923"
        state = appmod._client_state(fake)
        self.assertIsNotNone(state)
        decoded = json.loads(base64.b64decode(state))
        self.assertEqual(decoded["system_id"], "12345678")


class FintsClientStateRealLibraryTest(unittest.TestCase):
    """Round-trips deconstruct()/from_data() against the real python-fints
    client (not the FakeClient stand-in above). Both methods are pure
    (de)serialization — no dialog, no HTTP, no bank — so this stays inside
    the "never talks to a real bank" rule while proving the sidecar's
    client_state really is what python-fints itself can restore from."""

    def _client(self, **kwargs):
        return FinTS3PinTanClient(
            "00000000",
            "dummy-test-login",
            PIN_VALUE,
            "https://example.invalid/fints",
            product_id="TEST",
            **kwargs,
        )

    def test_deconstruct_and_from_data_round_trip_the_mechanism_and_system_id(self):
        original = self._client()
        original.system_id = "12345678"
        original.allowed_security_functions = ["923"]
        original.set_tan_mechanism("923")

        blob = original.deconstruct(including_private=True)
        state = base64.b64encode(blob).decode()

        restored = self._client(from_data=base64.b64decode(state))
        self.assertEqual(restored.get_current_tan_mechanism(), "923")
        self.assertEqual(restored.system_id, "12345678")

    def test_pin_is_never_part_of_the_deconstructed_state(self):
        client = self._client()
        client.system_id = "12345678"
        client.allowed_security_functions = ["923"]
        client.set_tan_mechanism("923")

        blob = client.deconstruct(including_private=True)

        _, data = decompress_datablob(DATA_BLOB_MAGIC, blob)
        self.assertNotIn("pin", data)
        self.assertNotIn("password", data)
        self.assertNotIn(PIN_VALUE, repr(data))
        self.assertNotIn(PIN_VALUE.encode(), blob)


if __name__ == "__main__":
    unittest.main()
