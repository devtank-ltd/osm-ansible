import pytest

from crypt import Crypt

def test_incorrect_key_len():
    key = "abc"
    iv = "xxxxxxxxxxxxxxxx"
    with pytest.raises(ValueError):
        c = Crypt(key, iv)

def test_incorrect_iv_len():
    key = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    iv = "abc"

    with pytest.raises(ValueError):
        c = Crypt(key, iv)

def test_decrypt():
    text = "Hello devtank"
    key = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    iv = "zzzzzzzzzzzzzzzz"
    c = Crypt(key, iv)
    enc_txt = c.encrypt(text)
    assert c.decrypt(enc_txt) == "Hello devtank"
