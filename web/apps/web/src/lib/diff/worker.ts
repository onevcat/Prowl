self.onmessage = (event: MessageEvent<string>) => {
  self.postMessage({ hunks: event.data.split("\n") });
};
