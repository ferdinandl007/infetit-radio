"""Build portable YuE2 model assets on a Mac. Inference uses Swift/Core ML only."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from graphs import (
    HEAD_DIM, HIDDEN, KV_HEADS, LATENT, LAYERS, GGUFReader, MIL, Transformer,
    build_decoder, ct, growable_decode, mb, np, past_layer, spec, stateful_decode, types,
)


def prefill(model, count, batch=2):
    @mb.program(input_specs=[
        spec(batch, count, HIDDEN), spec(batch, 1, count, 64), spec(batch, 1, count, 64),
        spec(batch, 1, 2 * count, count), mb.TensorSpec((batch,), dtype=types.int32),
    ], opset_version=ct.target.macOS15)
    def graph(embedding, sine, cosine, mask, last_indices):
        keys, values = [], []
        x = embedding
        for layer in range(LAYERS):
            x, k, v = model.block(x, layer, sine, cosine, mask=mask)
            keys.append(k)
            values.append(v)
        flattened = mb.reshape(x=x, shape=[batch * count, HIDDEN])
        tail = mb.reshape(x=mb.gather(x=flattened, indices=last_indices, axis=0), shape=[batch, 1, HIDDEN])
        logits = mb.identity(x=model.head(tail), name="logits")
        return logits, mb.stack(values=keys, axis=0, name="prefix_keys"), mb.stack(values=values, axis=0, name="prefix_values")
    return graph


def acoustic(model, prompt, frames):
    length = frames + 2
    capacity = prompt + frames + 1
    @mb.program(input_specs=[
        spec(1, length, LATENT), spec(1, 1, 256), spec(1, 1, length, 64), spec(1, 1, length, 64),
        spec(1, 1, 1, capacity + length), spec(LAYERS, 1, KV_HEADS, capacity, HEAD_DIM),
        spec(LAYERS, 1, KV_HEADS, capacity, HEAD_DIM),
    ], opset_version=ct.target.macOS15)
    def graph(latent_state, timestep, sine, cosine, mask, keys, values):
        hidden = model.linear(latent_state, "vae2llm", bias=True)
        time = model.linear(timestep, "time_embedder.mlp.0", bias=True)
        time = model.linear(mb.silu(x=time), "time_embedder.mlp.2", bias=True)
        pos = model.tensors["latent_pos_embed.pe"].data[:length].copy()[None]
        hidden = mb.add(x=mb.add(x=hidden, y=time), y=pos)
        for layer in range(LAYERS):
            cache = (past_layer(keys, layer, 1, capacity), past_layer(values, layer, 1, capacity))
            hidden, _, _ = model.block(hidden, layer, sine, cosine, mask=mask, past=cache, nar=True)
        output = model.linear(model.rms(hidden, "model.norm"), "llm2vae", bias=True)
        return mb.slice_by_index(x=output, begin=[0, 1, 0], end=[1, length-1, LATENT], name="velocity")
    return graph


def waveform(vae, config):
    weights = {t.name.removeprefix("vae_weights/"): t.data for t in GGUFReader(vae).tensors
               if t.name.startswith("vae_weights/decoder.")}
    @mb.program(input_specs=[spec(1, LATENT, 1, 128)], opset_version=ct.target.macOS15)
    def graph(latents):
        return mb.identity(x=build_decoder(MIL, latents, weights, config), name="waveform")
    return graph


def convert_graph(program, package):
    options = {}
    if isinstance(program, tuple):
        program, options["inputs"] = program
    ct.convert(program, convert_to="mlprogram", minimum_deployment_target=ct.target.macOS15,
               skip_model_load=True, package_dir=str(package), **options)


def publish_package(out, package, platform, keep_packages):
    destination = out / f"{package.stem}.mlmodelc"
    raw_package = out / package.name
    if keep_packages and not raw_package.exists():
        shutil.copytree(package, raw_package)
    if destination.exists():
        return
    system, target = {
        "macosx": ("macOS", "15.0"), "iphoneos": ("iOS", "18.0"), "xros": ("visionOS", "2.0"),
    }[platform]
    subprocess.run(["xcrun", "--sdk", platform, "coremlcompiler", "compile", str(package),
                    str(package.parent), "--platform", system, "--deployment-target", target], check=True)
    (package.parent / destination.name).rename(destination)


def already_built(out, name, keep_packages):
    return ((out / f"{name}.mlmodelc").exists()
            and (not keep_packages or (out / f"{name}.mlpackage").exists()))


def publish_graph(out, name, build, platform, keep_packages):
    if already_built(out, name, keep_packages):
        return
    with tempfile.TemporaryDirectory(dir=out) as temporary:
        package = Path(temporary) / f"{name}.mlpackage"
        convert_graph(build(), package)
        publish_package(out, package, platform, keep_packages)


def publish_autoregressive(out, functions, platform, keep_packages):
    name = "Autoregressive"
    if already_built(out, name, keep_packages):
        return
    with tempfile.TemporaryDirectory(dir=out) as temporary:
        directory = Path(temporary)
        package = directory / f"{name}.mlpackage"
        # The source graphs retain their own input and MLState shapes.
        with tempfile.TemporaryDirectory(dir=directory) as originals:
            descriptor = ct.utils.MultiFunctionDescriptor()
            for function, build in functions:
                source = Path(originals) / f"{function}.mlpackage"
                convert_graph(build(), source)
                descriptor.add_function(str(source), src_function_name="main", target_function_name=function)
            descriptor.default_function_name = "Prefill"
            ct.utils.save_multifunction(descriptor, str(package))
        publish_package(out, package, platform, keep_packages)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("weights", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--prompt-capacity", type=int,
                        help="Total tokens for instructions, sound description, and lyrics (macOS: 5024; iOS and visionOS: 512).")
    parser.add_argument("--decoder-frames", type=int, nargs="+", default=[1104, 3152, 5200])
    parser.add_argument("--acoustic-frames", type=int, nargs="+", default=[512, 4096, 5200])
    parser.add_argument("--platform", choices=("macosx", "iphoneos", "xros"), default="macosx")
    parser.add_argument("--keep-packages", action="store_true")
    parser.add_argument("--fast-acoustic", action="store_true",
                        help="Add the optional 3328-frame full-context acoustic graph.")
    parser.add_argument("--shared-weights", action="store_true",
                        help="Store the prefill and decoder functions together with shared weights.")
    parser.add_argument("--growable-cache", action="store_true",
                        help="Build a version 3 bundle for the growable Core ML or indexed Metal decoder.")
    parser.add_argument("--conditioning-batch", type=int, choices=(1, 2), default=2,
                        help="Use 1 to omit the unconditional branch for embedded radio.")
    parser.add_argument("--extend-metal-to", type=int, metavar="FRAMES",
                        help="Add a full-context acoustic graph to an existing indexed version 3 bundle.")
    args = parser.parse_args()
    if args.extend_metal_to is not None:
        output = args.output.resolve()
        manifest_path = output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        settings = json.loads((output / "build-settings.json").read_text())
        frames = args.extend_metal_to
        if (manifest["version"] != 3 or not (output / "metal-decoder.json").is_file()
                or settings["compilerPlatform"] != args.platform
                or not manifest["decoderFrames"][-1] < frames <= 6400):
            parser.error("Use an indexed version 3 bundle for this platform and a Metal ceiling above its decoder ceiling, up to 6400 frames.")
        model = Transformer(args.weights.resolve() / "yue2-3b-q4_0.gguf")
        if model.tensors["latent_pos_embed.pe"].data.shape[0] < frames + 2:
            parser.error("The model has too few acoustic position embeddings for that duration.")
        publish_graph(output, f"Acoustic{frames}", lambda: acoustic(model, manifest["promptCapacity"], frames),
                      args.platform, args.keep_packages)
        manifest["acousticFrames"] = sorted(set(manifest["acousticFrames"]) | {frames})
        manifest["metalFrames"] = frames
        pending = output / "manifest.part"
        pending.write_text(json.dumps(manifest, indent=2) + "\n")
        pending.replace(manifest_path)
        return
    p = args.prompt_capacity
    if p is None:
        p = 5024 if args.platform == "macosx" else 512
    batch = args.conditioning_batch
    ar, flow = args.decoder_frames, args.acoustic_frames
    if args.growable_cache and (batch != 2 or args.shared_weights):
        parser.error("--growable-cache uses shared weights and requires two conditioning branches.")
    if not (32 <= p <= 5024 and ar == sorted(set(ar)) and flow == sorted(set(flow)) and
            all(128 <= f <= 5200 for f in ar + flow) and flow[-1] >= ar[-1]):
        parser.error("Use ordered unique capacities, a prompt size of 32–5024, and an acoustic graph covering the decoder ceiling.")
    weights, output = args.weights.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    manifest = dict(version=3 if args.growable_cache else 2 if args.shared_weights else 1, promptCapacity=p, decoderFrames=ar, acousticFrames=flow)
    if batch == 1:
        manifest["conditioningBatch"] = batch
    manifest_path = output / "manifest.json"
    if manifest_path.exists() and json.loads(manifest_path.read_text()) != manifest:
        parser.error("Use a new output directory for a different asset configuration.")
    build_path = output / "build-settings.json"
    settings = {**manifest, "compilerPlatform": args.platform}
    if build_path.exists():
        if json.loads(build_path.read_text()) != settings:
            parser.error("The interrupted asset build used different settings.")
    else:
        if any(output.glob("*.mlmodelc")):
            parser.error("Existing compiled models lack build settings. Use a new asset directory.")
        pending = output / "build-settings.part"
        pending.write_text(json.dumps(settings, indent=2) + "\n")
        pending.rename(build_path)
    model = Transformer(weights / "yue2-3b-q4_0.gguf")
    embeddings = model.tensors["model.embed_tokens.weight"].data
    if embeddings.dtype != np.float16 or embeddings.shape != (184704, HIDDEN):
        raise ValueError("Unexpected embedding table shape or precision")
    if not (output / "embeddings.f16").exists():
        temporary = output / "embeddings.part"
        embeddings.tofile(temporary)
        temporary.rename(output / "embeddings.f16")
    shutil.copyfile(weights / "sidecars/yue2-qwen.tiktoken", output / "tokenizer.tiktoken")
    functions = [("Prefill", lambda: prefill(model, p, batch))]
    if args.growable_cache:
        functions.append(("GrowableDecoder", lambda: growable_decode(model, p + ar[-1] + 1)))
    else:
        functions += [(f"Decoder{f}", lambda f=f: stateful_decode(model, p + f + 1, batch)) for f in ar]
    if args.shared_weights or args.growable_cache:
        publish_autoregressive(output, functions, args.platform, args.keep_packages)
    else:
        for name, build in functions:
            publish_graph(output, name, build, args.platform, args.keep_packages)
    acoustic_sizes = sorted(set(flow + ([3328] if args.fast_acoustic and max(flow) > 3328 else [])))
    jobs = [(f"Acoustic{f}", lambda f=f: acoustic(model, p, f)) for f in acoustic_sizes]
    jobs += [("Waveform", lambda: waveform(weights / "yue2-vae-f16.gguf",
                        json.loads((weights / "sidecars/yue2-vae-config.json").read_text())))]
    for name, build in jobs:
        publish_graph(output, name, build, args.platform, args.keep_packages)
    temp_manifest = output / "manifest.part"
    temp_manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    temp_manifest.rename(manifest_path)


if __name__ == "__main__":
    main()
