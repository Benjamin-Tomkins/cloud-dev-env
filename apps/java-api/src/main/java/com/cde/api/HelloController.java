package com.cde.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.net.InetAddress;
import java.net.UnknownHostException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

@RestController
public class HelloController {

    @GetMapping("/")
    public Map<String, Object> root() throws UnknownHostException {
        boolean vaultInjected = Files.exists(Path.of("/vault/secrets/config"));
        return Map.of(
            "service", "java-api",
            "message", "Hello from Java!",
            "host", InetAddress.getLocalHost().getHostName(),
            "vault_injected", vaultInjected
        );
    }

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("status", "healthy");
    }
}
