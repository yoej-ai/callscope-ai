import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { resolveSafeAuthRedirect } from "../lib/auth/redirect-target.mjs";

const CALLBACK_URL = "https://app.example.com/auth/callback?code=test";
const FALLBACK_URL = "https://app.example.com/dashboard";

describe("resolveSafeAuthRedirect", () => {
  it("accepts same-origin application paths and query strings", () => {
    assert.equal(
      resolveSafeAuthRedirect(CALLBACK_URL, "/dashboard").href,
      "https://app.example.com/dashboard",
    );
    assert.equal(
      resolveSafeAuthRedirect(
        CALLBACK_URL,
        "/dashboard/calls/123?tab=analysis",
      ).href,
      "https://app.example.com/dashboard/calls/123?tab=analysis",
    );
  });

  it("falls back for missing, empty, absolute, or protocol-relative targets", () => {
    for (const target of [
      null,
      "",
      "dashboard",
      "https://evil.example/path",
      "//evil.example/path",
    ]) {
      assert.equal(
        resolveSafeAuthRedirect(CALLBACK_URL, target).href,
        FALLBACK_URL,
      );
    }
  });

  it("rejects raw and encoded backslash redirect tricks", () => {
    for (const target of [
      "/\\\\evil.example/path",
      "/%5C%5Cevil.example/path",
      "/%255C%255Cevil.example/path",
      "/dashboard\\evil.example",
    ]) {
      assert.equal(
        resolveSafeAuthRedirect(CALLBACK_URL, target).href,
        FALLBACK_URL,
      );
    }
  });

  it("rejects the encoded callback attack after query parsing", () => {
    const callback = new URL(
      `${CALLBACK_URL}&next=/%5C%5Cevil.example/path`,
    );

    assert.equal(
      resolveSafeAuthRedirect(
        callback,
        callback.searchParams.get("next"),
      ).href,
      FALLBACK_URL,
    );
  });

  it("rejects encoded protocol-relative, control, and malformed targets", () => {
    for (const target of [
      "/%2F%2Fevil.example/path",
      "/dashboard%0Aevil",
      "/dashboard\u0000evil",
      "/dashboard%",
    ]) {
      assert.equal(
        resolveSafeAuthRedirect(CALLBACK_URL, target).href,
        FALLBACK_URL,
      );
    }
  });
});
