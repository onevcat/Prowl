type ViewTransitionDocument = Document & {
  startViewTransition?: (update: () => void) => unknown;
};

export function runViewTransition(update: () => void, documentRef: Document | undefined = globalDocument()): void {
  const startViewTransition = (documentRef as ViewTransitionDocument | undefined)?.startViewTransition;
  if (!startViewTransition) {
    update();
    return;
  }
  startViewTransition.call(documentRef, update);
}

function globalDocument(): Document | undefined {
  return typeof document === "undefined" ? undefined : document;
}
