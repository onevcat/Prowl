self.onmessage = (event: MessageEvent<string>) => {
  self.postMessage(event.data);
};
