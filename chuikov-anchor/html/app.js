const activeSounds = new Map();

function stopSound(soundId) {
    const sound = activeSounds.get(soundId);

    if (!sound) {
        return;
    }

    sound.pause();
    sound.currentTime = 0;
    activeSounds.delete(soundId);
}

function stopAllSounds() {
    for (const soundId of activeSounds.keys()) {
        stopSound(soundId);
    }
}

window.addEventListener('message', (event) => {
    const data = event.data;

    if (!data || typeof data.action !== 'string') {
        return;
    }

    if (data.action === 'stopAnchorSound') {
        if (typeof data.soundId === 'string') {
            stopSound(data.soundId);
        }
        return;
    }

    if (data.action === 'stopAllAnchorSounds') {
        stopAllSounds();
        return;
    }

    if (data.action === 'setAnchorSoundVolume') {
        const sound = typeof data.soundId === 'string'
            ? activeSounds.get(data.soundId)
            : null;
        const requestedVolume = Number(data.volume);

        if (sound && Number.isFinite(requestedVolume)) {
            sound.volume = Math.min(1, Math.max(0, requestedVolume));
        }
        return;
    }

    if (data.action !== 'playAnchorSound'
        || typeof data.soundId !== 'string'
        || data.soundId.length === 0
        || typeof data.file !== 'string'
        || data.file.length === 0) {
        return;
    }

    stopSound(data.soundId);

    const requestedVolume = Number(data.volume);
    const volume = Number.isFinite(requestedVolume)
        ? Math.min(1, Math.max(0, requestedVolume))
        : 0.75;

    const sound = new Audio(data.file);
    activeSounds.set(data.soundId, sound);
    sound.volume = volume;

    sound.addEventListener('ended', () => {
        if (activeSounds.get(data.soundId) === sound) {
            activeSounds.delete(data.soundId);
        }
    }, { once: true });

    sound.addEventListener('error', () => {
        if (activeSounds.get(data.soundId) === sound) {
            activeSounds.delete(data.soundId);
        }

        console.error(`[chuikov-anchor] Ses dosyası yüklenemedi: ${data.file}`);
    }, { once: true });

    sound.play().catch((error) => {
        if (activeSounds.get(data.soundId) === sound) {
            activeSounds.delete(data.soundId);
        }

        console.error('[chuikov-anchor] Ses oynatılamadı:', error);
    });
});
