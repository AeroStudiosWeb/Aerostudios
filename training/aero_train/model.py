"""Small fully trainable RGB denoiser. Compatible with AeroEnhance's fixed 256x256 ONNX input.

This is a starting model, not a claim of SCUNet/Topaz-equivalent quality. Trained
weights remain a separate artifact, never included in or changed by this source.
"""
import torch
from torch import nn


class AeroDenoiseNet(nn.Module):
    """Residual convolutional RGB denoiser. Input/output float32 NCHW, values ~[0,1]."""
    def __init__(self, width: int = 48, depth: int = 7):
        super().__init__()
        if width < 8 or width > 256 or depth < 3 or depth > 32:
            raise ValueError("width must be 8..256, depth 3..32")
        layers: list[nn.Module] = [nn.Conv2d(3, width, 3, padding=1), nn.ReLU(inplace=True)]
        for _ in range(depth - 2):
            layers += [nn.Conv2d(width, width, 3, padding=1), nn.ReLU(inplace=True)]
        layers.append(nn.Conv2d(width, 3, 3, padding=1))
        self.net = nn.Sequential(*layers)
        # Start near identity: safe initialization for detail preservation.
        nn.init.zeros_(self.net[-1].weight)
        nn.init.zeros_(self.net[-1].bias)
        self.width, self.depth = width, depth

    def forward(self, noisy: torch.Tensor) -> torch.Tensor:
        # No clamp here, to keep training gradients smooth; app clamps on export.
        return noisy - self.net(noisy)


def synthetic_noise(clean: torch.Tensor) -> torch.Tensor:
    """Approximate shot/read noise with small random colour imbalance and row banding.

    Assumes clean is [B,3,H,W] and in [0,1]. It is NOT a raw Bayer sensor model.
    """
    b = clean.size(0)
    device, dtype = clean.device, clean.dtype
    # Photon counts vary over orders of magnitude (high ISO vs good daylight).
    photons = torch.exp(torch.empty(b, 1, 1, 1, device=device, dtype=dtype).uniform_(4.2, 8.0))
    shot = torch.poisson((clean.clamp(0, 1) * photons).float()).to(dtype) / photons
    read_sigma = torch.empty(b, 1, 1, 1, device=device, dtype=dtype).uniform_(0.003, 0.027)
    channel_mul = torch.empty(b, 3, 1, 1, device=device, dtype=dtype).uniform_(0.85, 1.2)
    read_noise = torch.randn_like(clean) * read_sigma * channel_mul
    rows = torch.randn(b, 1, clean.shape[2], 1, device=device, dtype=dtype) * (read_sigma * 0.28)
    return (shot + read_noise + rows).clamp(0, 1)


def edge_mae(a: torch.Tensor, b: torch.Tensor) -> torch.Tensor:
    """Difference of image gradients; catches many edge-loss/halo regressions."""
    dx = (a[..., :, 1:] - a[..., :, :-1]) - (b[..., :, 1:] - b[..., :, :-1])
    dy = (a[..., 1:, :] - a[..., :-1, :]) - (b[..., 1:, :] - b[..., :-1, :])
    return (dx.abs().mean() + dy.abs().mean()) / 2


def psnr(a: torch.Tensor, b: torch.Tensor) -> float:
    mse = (a.clamp(0, 1) - b).square().mean().item()
    return -10.0 * __import__('math').log10(max(mse, 1e-12))
