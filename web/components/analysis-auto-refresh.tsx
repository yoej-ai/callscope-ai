"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

type AnalysisAutoRefreshProps = {
  active: boolean;
  intervalMs?: number;
};

export function AnalysisAutoRefresh({
  active,
  intervalMs = 5000,
}: AnalysisAutoRefreshProps) {
  const router = useRouter();

  useEffect(() => {
    if (!active) return;

    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") {
        router.refresh();
      }
    }, intervalMs);

    return () => {
      window.clearInterval(timer);
    };
  }, [active, intervalMs, router]);

  return null;
}