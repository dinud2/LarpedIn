
def prepare_linkedin_post(caption, image_path):
    return {
        "caption": caption,
        "image_path": image_path,
        "status": "draft"
    }


post = prepare_linkedin_post(
    "Today I dropped my coffee. Here's what it taught me about leadership.",
    "sample.jpg"
)

print(post)
